import Foundation

// MARK: - Subscription
// One imported subscription: a URL (or local file) that yields sources.
// Supported inputs (v1):
//  - TVBox JSON: { "sites": [ { "key","name","type":1|4,"api", ... } ] }
//  - Cat bundle: a .js / .js.md5 URL (see CatSource.swift — the .md5 is a
//    checksum file, not the bundle itself; the bundle is fetched at the
//    same URL minus the ".md5" suffix and its hash is verified).
//  - Local file: a .json / .txt / .js file imported from the Files app.
// Failure policy (Yingxia SubscriptionMerge): a failed refresh NEVER
// wipes the last good config — the old sources stay usable and the
// error is shown next to the subscription instead.
public struct Subscription: Identifiable, Hashable, Codable {
    public var id: UUID
    public var name: String
    public var url: URL?           // nil = local file import
    public var localFileName: String?
    public var kind: Kind
    public var sources: [Source]
    public var lastGoodAt: Date?
    public var lastError: String?

    public enum Kind: String, Codable, Hashable {
        case tvboxJSON
        case catBundle
        case localFile
    }

    public init(id: UUID = UUID(), name: String, url: URL? = nil,
                localFileName: String? = nil, kind: Kind,
                sources: [Source] = [], lastGoodAt: Date? = nil,
                lastError: String? = nil) {
        self.id = id; self.name = name; self.url = url
        self.localFileName = localFileName; self.kind = kind
        self.sources = sources; self.lastGoodAt = lastGoodAt; self.lastError = lastError
    }
}

// MARK: - SubscriptionStore
// Persists subscriptions + the merged source list in UserDefaults (v1).
// v2 can move this to SwiftData / Core Data without changing call sites.
@MainActor
public final class SubscriptionStore: ObservableObject {
    @Published public private(set) var subscriptions: [Subscription] = []
    @Published public private(set) var lastError: String?

    private let defaultsKey = "yiplayer.subscriptions.v1"
    private let defaults = UserDefaults.standard

    public init() { load() }

    public var allSources: [Source] {
        subscriptions.flatMap(\.sources)
    }

    public func add(_ subscription: Subscription) {
        subscriptions.append(subscription)
        save()
    }

    public func remove(id: UUID) {
        subscriptions.removeAll { $0.id == id }
        save()
    }

    /// Replace one subscription's sources after a successful refresh only.
    /// On failure the caller keeps the old sources and records the error.
    public func refreshSucceeded(id: UUID, sources: [Source]) {
        guard let i = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        subscriptions[i].sources = sources
        subscriptions[i].lastGoodAt = Date()
        subscriptions[i].lastError = nil
        save()
    }

    public func refreshFailed(id: UUID, error: String) {
        guard let i = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        subscriptions[i].lastError = error // old sources are kept untouched
        save()
    }

    private func load() {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([Subscription].self, from: data)
        else { subscriptions = []; return }
        subscriptions = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(subscriptions) {
            defaults.set(data, forKey: defaultsKey)
        }
    }
}

// MARK: - Subscription importing (URL / file)
public enum SubscriptionImporter {
    /// The default test cat subscription from the user's catvodsub.txt.
    public static let defaultCatURL = URL(string: "https://9280.kstore.vip/cat/index.js.md5")!

    /// Resolve a relative URL against the subscription's final URL
    /// (Yingxia: relative URLs are resolved against the subscription's
    /// final response address, not the URL the user typed).
    public static func resolve(_ relative: String, against base: URL) -> URL? {
        URL(string: relative, relativeTo: base)?.absoluteURL
    }

    /// Fetch a subscription document. Returns the raw text and its final URL.
    /// The .md5 suffix is NOT fetched as the bundle — see CatSource.md5 handling.
    public static func fetch(url: URL) async throws -> (text: String, finalURL: URL) {
        var request = URLRequest(url: url)
        request.setValue("YiPlayer/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SourceError.network("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw SourceError.parse("订阅不是 UTF-8 文本")
        }
        return (text, response.url ?? url)
    }
}
