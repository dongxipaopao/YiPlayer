import Foundation

// MARK: - Subscription
// One imported subscription: a URL (or local file) that yields sources.
// Supported inputs (v2):
//  - TVBox JSON: { "sites": [ { "key","name","type":1|4,"api", ... } ] }
//  - Cat bundle: a .js / .js.md5 URL (see CatSource.swift — the .md5 is a
//    checksum file, not the bundle itself; the bundle is fetched at the
//    same URL minus the ".md5" suffix and its hash is verified).
//  - Py spider: a .py file (pd.py or any CatVod py spider), run by the
//    embedded CPython host (see PySource.swift).
//  - Local file: a .json / .txt / .js / .py file imported from the Files app.
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
        case pySpider
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

    public init() {
        load()
        seedDefaultsIfNeeded()
    }

    /// First launch (v2): the app must not open empty. v1 shipped with
    /// zero sources, so "nothing runs" until the user finds the import
    /// page — that is exactly what the user reported. Seed the two
    /// sources the user actually uses, once, and let them delete or
    /// add more in Settings:
    ///   1. 懂片帝 (py, bundled pd.py) — homeVideoContent works on
    ///      first launch, no import needed.
    ///   2. 9280 猫源 (cat, .md5 URL) — the Node.js server bundle.
    /// Runs only when there are no subscriptions at all AND the seed
    /// flag was never set, so a user who deleted everything on purpose
    /// does not get them back.
    private func seedDefaultsIfNeeded() {
        guard subscriptions.isEmpty,
              !UserDefaults.standard.bool(forKey: "yiplayer.seeded.v2") else { return }
        UserDefaults.standard.set(true, forKey: "yiplayer.seeded.v2")
        var seeded: [Subscription] = []
        if let pdURL = Bundle.main.url(forResource: "pd", withExtension: "py",
                                       subdirectory: "spiders") {
            let id = UUID()
            let source = Source(id: "py-dongpian", name: "懂片帝", kind: .py,
                                api: pdURL, spider: "pd.py",
                                subscriptionID: id.uuidString)
            seeded.append(Subscription(id: id, name: "懂片帝", url: pdURL,
                                       kind: .pySpider, sources: [source],
                                       lastGoodAt: Date()))
        }
        let catID = UUID()
        let catSource = Source(id: "cat-9280", name: "9280 猫源", kind: .cat,
                               api: SubscriptionImporter.defaultCatURL,
                               subscriptionID: catID.uuidString)
        seeded.append(Subscription(id: catID, name: "9280 猫源",
                                   url: SubscriptionImporter.defaultCatURL,
                                   kind: .catBundle, sources: [catSource],
                                   lastGoodAt: Date()))
        subscriptions = seeded
        save()
    }

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
