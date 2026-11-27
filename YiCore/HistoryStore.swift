import Foundation

// MARK: - HistoryStore ("Continue Watching")
// Persists per-title progress. Kept deliberately tiny in v1:
// title id + episode + seconds + duration + updated date, in UserDefaults.
// No cloud sync in v1 (Rex/Noctra do Trakt/iCloud — that is v2).
@MainActor
public final class HistoryStore: ObservableObject {
    public struct Entry: Identifiable, Hashable, Codable {
        public var id: String        // VideoItem.id + sourceID
        public var title: String
        public var coverURL: URL?
        public var episodeID: String?
        public var episodeName: String?
        public var position: Double  // seconds watched
        public var duration: Double  // seconds, 0 = unknown
        public var updatedAt: Date

        public var progress: Double {
            guard duration > 0 else { return 0 }
            return min(1, max(0, position / duration))
        }
        public var isFinished: Bool { progress >= 0.95 }
    }

    @Published public private(set) var entries: [Entry] = []

    private let defaultsKey = "yiplayer.history.v1"
    private let defaults = UserDefaults.standard

    public init() { load() }

    public var continueWatching: [Entry] {
        entries.filter { !$0.isFinished }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func record(item: VideoItem, episode: Episode?,
                      position: Double, duration: Double) {
        let key = "\(item.sourceID):\(item.id)"
        let entry = Entry(id: key, title: item.title, coverURL: item.coverURL,
                          episodeID: episode?.id, episodeName: episode?.name,
                          position: position, duration: duration, updatedAt: Date())
        entries.removeAll { $0.id == key }
        entries.insert(entry, at: 0)
        entries = Array(entries.prefix(100))
        save()
    }

    public func remove(id: String) {
        entries.removeAll { $0.id == id }
        save()
    }

    public func clear() { entries = []; save() }

    private func load() {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data)
        else { return }
        entries = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: defaultsKey)
        }
    }
}
