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
    public var spider: String?     // cat/py: spider file name or inline script id (ext / spider field)
    public var isSearchable: Bool
    public var isChangeable: Bool
    public var subscriptionID: String

    public init(id: String, name: String, kind: SourceKind, api: URL,
                spider: String? = nil, isSearchable: Bool = true,
                isChangeable: Bool = true, subscriptionID: String) {
        self.id = id; self.name = name; self.kind = kind; self.api = api
        self.spider = spider; self.isSearchable = isSearchable
        self.isChangeable = isChangeable; self.subscriptionID = subscriptionID
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
