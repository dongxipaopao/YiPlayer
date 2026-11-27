import Foundation

// MARK: - PySource
// A CatVod Python spider source: pd.py ("懂片帝", site
// https://dongpian17.com), already in this repo at the root as pd.py
// (522 lines, read 2026-11-27). Its real interface, NOT invented:
//
//   class Spider(base.spider.Spider):   # needs base/ one level up:
//     sys.path.append('..'); from base.spider import Spider
//     def init(self, extend=''): ...   # extend JSON: host / name / ua /
//                                       # account / password / cookie
//     def getName(self): ...            # "懂片帝"
//     def homeContent(self, filter): ...# classes: all 全部 / movie 电影 /
//       # series 剧集 / short_drama 短剧 / anime 动漫 / variety 综艺;
//       # filters: window 日榜/周榜/月榜/总榜 per kind
//     def homeVideoContent(self): ...   # GET /v1/feed/home
//       # ?scope=public&mode=preview&sections=3&cards=12
//     def categoryContent(self, tid, pg, filter, extend): ...
//       # GET /v1/browse/catalog?sort=trending&window=<day|week|month|total>
//       #   &page=<pg>&limit=20[&kind=<tid>]; pagecount = pg+1 if has_more
//     def detailContent(self, ids): ... # GET /v1/catalog/<vid>; episodes
//       # paged via /v1/catalog/<vid>/episodes?limit=48&offset=N;
//       # play ids are "<title>$<token>"; lines via
//       # GET /v1/playback/resolve/<first_token>?view=compact — official
//       # lines only (label 含"官方" or provider official-*/bytevod-*),
//       # 4K lines first; vod_play_from "$$$" joined, vod_play_url per
//       # line with each episode as "<title>$<token>@@<line_id>"
//     def searchContent(self, key, quick): ...
//       # GET /v1/browse/catalog?q=<key>&page=1&limit=20 (no pg param)
//     def playerContent(self, flag, id, vipFlags): ...
//       # id is "<token>" or "<token>@@<line_id>"; resolve via
//       # GET /v1/playback/resolve/<token>?view=compact, then
//       # POST /v1/playback/resolve-line {"ticket": ...} for
//       # resolve:// tickets; login is automatic: account/password
//       # POST /v1/users/password/login, else anonymous
//       # POST /v1/users/anonymous (ai_movie_session cookie).
//       # Returns {"parse": 0, "playUrl": "", "url": <m3u8>,
//       #          "header": {"User-Agent": <ua>}}.
//     def localProxy(self, param): ...  # no-op (pass) in pd.py
//   All /v1/* calls are HMAC-SHA256 signed (key in pd.py):
//   message = "<METHOD>\n<path><query>\n<timestamp-ms>\n<nonce-hex>",
//   headers x-ai-movie-timestamp / -nonce / -signature plus
//   x-ai-movie-client-name/-version/-build-version/-protocol-version.
//   This is NOT the 555.py MacCMS interface: no numeric vod_id,
//   no "{id}-{sid}-{nid}" play id, no localProxy m3u8 rewriting.
//
// v1 STATUS: STUB. iOS has no Python runtime in this build, so every
// call returns a clear, honest error (the same wording Yingxia uses:
// "This source requires a Python runtime, which is not available on
// this platform."). The call sites are already wired — dropping a real
// host in later does not change any caller. pd.py itself is in the repo
// (root pd.py) so v2 can load it without re-importing; YiPlayer ships
// no video library of its own.
//
// v2 path (documented in the reference research, not built here):
// embed CPython 3.14 (BeeWare Python-Apple-support, as in Yingxia's
// Docs/python-runtime-plan.md) behind a C bridge, one interpreter per
// source, stdlib + requests/bs4/lxml/pycryptodome only, ~+66 MB per
// platform. MarcoMovie's iOS native Python loader is the other proven
// route. Either way the host must also provide pd.py's `base.spider`
// package one level up (sys.path.append('..')) and a `requests`
// session — a bare CPython without those will fail at import.
public protocol PySourceHost: AnyObject {
    /// Load a spider file (pd.py or any CatVod py spider) for this source.
    func loadSpider(source: Source, script: String) throws
    func home(source: Source, filter: [String: String]) async throws -> [VideoItem]
    func category(source: Source, typeID: String, page: Int) async throws -> (items: [VideoItem], pageCount: Int)
    func detail(source: Source, vodID: String) async throws -> VideoItem
    func search(source: Source, keyword: String, page: Int) async throws -> [VideoItem]
    func playLines(source: Source, episode: Episode) async throws -> [PlayLine]
}

/// v1 implementation: always explains itself, never pretends to play.
public final class EmbeddedPythonHost: PySourceHost {
    public static let unavailableMessage =
        "iOS 暂不支持 Python 运行时（v2 嵌入 CPython，参考 Yingxia python-runtime-plan）"

    public init() {}

    public func loadSpider(source: Source, script: String) throws {
        // Deliberately NOT storing the script as "loaded": claiming it is
        // ready would be a lie. The file is kept by the caller so v2 can
        // load it without re-importing.
        throw SourceError.notSupported(Self.unavailableMessage)
    }

    public func home(source: Source, filter: [String: String]) async throws -> [VideoItem] {
        throw SourceError.notSupported(Self.unavailableMessage)
    }

    public func category(source: Source, typeID: String, page: Int) async throws -> (items: [VideoItem], pageCount: Int) {
        throw SourceError.notSupported(Self.unavailableMessage)
    }

    public func detail(source: Source, vodID: String) async throws -> VideoItem {
        throw SourceError.notSupported(Self.unavailableMessage)
    }

    public func search(source: Source, keyword: String, page: Int) async throws -> [VideoItem] {
        throw SourceError.notSupported(Self.unavailableMessage)
    }

    public func playLines(source: Source, episode: Episode) async throws -> [PlayLine] {
        throw SourceError.notSupported(Self.unavailableMessage)
    }
}

// MARK: - PySource runner (wires the stub host to SourceRunner)
public final class PySource: SourceRunner {
    public let source: Source
    private let host: PySourceHost
    /// The spider script text (e.g. pd.py), kept so v2 can load it.
    /// v1 never executes it.
    public var spiderScript: String?

    public init(source: Source, host: PySourceHost = EmbeddedPythonHost()) {
        self.source = source
        self.host = host
    }

    public func home(filter: [String: String]) async throws -> [VideoItem] {
        try await host.home(source: source, filter: filter)
    }

    public func category(typeID: String, page: Int) async throws -> (items: [VideoItem], pageCount: Int) {
        try await host.category(source: source, typeID: typeID, page: page)
    }

    public func detail(vodID: String) async throws -> VideoItem {
        try await host.detail(source: source, vodID: vodID)
    }

    public func search(keyword: String, page: Int) async throws -> [VideoItem] {
        try await host.search(source: source, keyword: keyword, page: page)
    }

    public func playLines(for episode: Episode) async throws -> [PlayLine] {
        try await host.playLines(source: source, episode: episode)
    }
}
