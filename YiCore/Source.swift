import Foundation

// MARK: - Source
// A single playable source inside one subscription.
// kind mirrors the TVBox / CatVod source taxonomy (research-tvbox-marcotv.md):
//  - json type 1 / type 4 : TVBox JSON (MacCMS JSON/XML, home/category/search/detail/play)
//  - cat                 : CatVod JS spider, run by CatJSRuntime (JavaScriptCore)
//  - py                  : CatVod Python spider, run by the embedded CPython host (v2, see PySource.swift)
public enum SourceKind: String, Codable, Hashable {
    case jsonType1
    case jsonType4
    case cat
    case py
}

public struct Source: Identifiable, Hashable, Codable {
    public var id: String          // stable key within its subscription
    public var name: String
    public var kind: SourceKind
    public var api: URL            // base URL / spider file URL, resolved against the subscription URL
    public var spider: String?     // cat/py: spider file name or inline script id (ext / spider field).
                                   // For an EXPANDED server-bundle site (v2.1.4) this is the site's
                                   // own route, e.g. "/spider/douban/3" — the runner uses it
                                   // verbatim instead of the legacy per-source siteKey.
    public var isSearchable: Bool
    public var isChangeable: Bool
    public var subscriptionID: String
    /// Display group for the Discover source picker (v2.1.4). For an
    /// expanded server-bundle site this is the tag after "|" in the
    /// bundle's /config name (e.g. "4K", "秒播"), or the bundle's own
    /// config group (video/read/comic/music/pan). "" = ungrouped
    /// (py / TVBox JSON / legacy single cat sources).
    public var group: String = ""

    public init(id: String, name: String, kind: SourceKind, api: URL,
                spider: String? = nil, isSearchable: Bool = true,
                isChangeable: Bool = true, subscriptionID: String,
                group: String = "") {
        self.id = id; self.name = name; self.kind = kind; self.api = api
        self.spider = spider; self.isSearchable = isSearchable
        self.isChangeable = isChangeable; self.subscriptionID = subscriptionID
        self.group = group
    }
}

// MARK: - Source protocol (what every source must do, regardless of kind)
//
// categories() and the filtered category() are REQUIREMENTS (not just
// extension methods) on purpose: an extension-only method on `any
// SourceRunner` would always run the default implementation, and a
// PySource/CatSource override would silently never be called (Swift
// dispatches protocol-extension methods statically). The extension
// below supplies the defaults, so JsonSource does not have to
// implement them.
public protocol SourceRunner: AnyObject {
    var source: Source { get }
    func home(filter: [String: String]) async throws -> [VideoItem]
    func categories() async throws -> [(id: String, name: String)]
    func category(typeID: String, page: Int) async throws -> (items: [VideoItem], pageCount: Int)
    func category(typeID: String, page: Int, filter: [String: String]) async throws -> (items: [VideoItem], pageCount: Int)
    func detail(vodID: String) async throws -> VideoItem
    /// Same, with the item's title. CatSource uses the title for its
    /// aggregator fallback (v2.1.4): a douban-style item's /detail is
    /// a stub in the bundle, so the lines are resolved by searching
    /// the bundle's other sites by title. The default ignores the
    /// title, so JsonSource / PySource need no change.
    func detail(vodID: String, title: String?) async throws -> VideoItem
    func search(keyword: String, page: Int) async throws -> [VideoItem]
    /// Resolve one episode to all of its playable lines (multi-line selectable).
    func playLines(for episode: Episode) async throws -> [PlayLine]
}

// MARK: - SourceRunner defaults (v2)
// Not every source kind has its own category list or filter. The
// defaults keep the v1 behaviour (555.py category ids, no filter);
// PySource and CatSource override categories(), and PySource overrides
// the filtered category (window 日榜/周榜/月榜/总榜).
public extension SourceRunner {
    func detail(vodID: String, title: String?) async throws -> VideoItem {
        try await detail(vodID: vodID)
    }

    func categories() async throws -> [(id: String, name: String)] {
        [("1", "电影"), ("2", "连续剧"), ("3", "综艺纪录"), ("4", "动漫"), ("126", "短剧")]
    }

    func category(typeID: String, page: Int, filter: [String: String]) async throws -> (items: [VideoItem], pageCount: Int) {
        try await category(typeID: typeID, page: page)
    }
}

public enum SourceError: LocalizedError {
    case notSupported(String)
    case network(String)
    case parse(String)
    case noResult

    public var errorDescription: String? {
        switch self {
        case .notSupported(let m): return m
        case .network(let m): return "网络错误：\(m)"
        case .parse(let m): return "解析失败：\(m)"
        case .noResult: return "没有找到相关资源"
        }
    }
}

// MARK: - Cancellation is not an error (v2.1)
//
// A view that went away mid-load, a search superseded by a newer
// query, a pull-to-refresh interrupted — none of these is a failure,
// and none of them may paint red text on the screen. v2.0.0 only
// caught CancellationError, but a cancelled URLSession task throws
// URLError with code .cancelled (localizedDescription is the bare
// English word "cancelled"), which fell into lastError and showed up
// as a red "cancelled" on an otherwise empty home page. Every view
// that shows an error must go through these two helpers.
public func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let urlError = error as? URLError, urlError.code == .cancelled { return true }
    if (error as NSError).code == NSUserCancelledError { return true }
    // A wrapped cancellation (e.g. an error whose message IS the
    // cancellation) is still a cancellation, not content.
    let text = error.localizedDescription.lowercased()
    return text == "cancelled" || text == "canceled"
}

/// The text a view may show for `error`, or nil when the error is a
/// cancellation (or is nothing but the word "cancelled").
public func displayableErrorMessage(_ error: Error) -> String? {
    if isCancellation(error) { return nil }
    let text = error.localizedDescription
    if text.lowercased().contains("cancelled") || text.lowercased().contains("canceled") {
        return nil
    }
    return text
}
