import Foundation

// MARK: - CatSource
// A CatVod JS ("cat") source. Two execution paths (v2):
//
//  1. websiteBundle / Spider bundles -> the bounded JavaScriptCore
//     host (Runtime/CatJSRuntime.swift), unchanged from v1.
//  2. Fastify SERVER bundles (e.g. the 9280.kstore.vip test bundle) ->
//     the embedded Node.js runtime (Runtime/NodeHost). The bundle is
//     .md5-verified first, written to Application Support, and started
//     as its own Fastify server on 127.0.0.1; calls go through the
//     control protocol in host.mjs (POST /call, /spider/<site>/{init,
//     home,category,detail,play,search}). The bundle's /config answer
//     lists its sites; each site's `api` field ("/spider/<key>/<type>")
//     is the route, because its keys are `nodejs_<key>` and cannot be
//     appended to /spider/.
//     v2.1.3: the 9280 bundle is a CatVodSpiderios STANDALONE server,
//     not an embeddable CatPawOpen bundle — it has no exports.start
//     (only dead-code module.exports) and autostarts only as
//     `node index.js` with no catServerFactory (see worker.mjs).
//     Its /config is grouped: {video:{sites:[...]},read:{sites:[]},
//     comic:{...},music:{...},pan:{...}}.
//
// The test URL https://9280.kstore.vip/cat/index.js.md5 returns ONE line:
//   d8e69da8c37a29afe50fdc8de9dbf268
// That is the MD5 checksum of index.js, NOT the bundle itself.
// The bundle at https://9280.kstore.vip/cat/index.js is a
// CatVodSpiderios STANDALONE Fastify server bundle. It is NOT the
// aaaaa2780009/cat-bundle build (65,702 lines, first line
// "// ====慕猫源", defines globalThis.websiteBundle), and NOT an
// embeddable CatPawOpen bundle: no exports.start, autostart only as
// `node index.js` (v2.1.3: worker.mjs standalone mode).
//
// v2.1.4 — READ THE BUNDLE FIRST (2026-11-28, re-downloaded and
// MD5-checked: d8e69da8c37a29afe50fdc8de9dbf268, unchanged). The
// /detail {} is the bundle's OWN answer, not a request-shape bug:
//  * The Fastify route is bound DIRECTLY to the spider's method —
//    `t.detail&&o.post("/detail",t.detail.bind(t))` — no wrapping,
//    no extra fields. The spider reads `body?.id` (other spiders:
//    `Array.isArray(n.body?.id)?n.body.id:[n.body?.id]`), exactly
//    the `{id}` body host.mjs already sends (host.mjs:252), and
//    host.mjs already POSTs /init per api before any call (245),
//    which the douban spider's init ignores anyway (it only handles
//    extend/ext). No body field, type, or init step can fix it.
//  * The douban spider (factory _c0, meta {key:"douban",
//    name:"豆瓣|首页",type:3}) has REAL home/category (it fetches
//    frodo.douban.com hot lists; items get id `msearch:<douban id>`
//    via mc0) but STUB detail/search/play:
//    `async detail(){return{}},async play(){return{}},async search(){return{}}`
//    — the ONLY two stub triples in the whole bundle; the other is
//    factory J70, meta {key:"gengxin",name:"日期:20261127",type:3},
//    the date-stamp marker. So a douban item's /detail genuinely
//    returns {} — and its search would too.
//  * Every other spider implements detail for real, e.g. wogg 玩偶:
//    `async detail(l){...for(let g of d.filter(Boolean)){let y=await
//    qWt(c.siteUrl,g,e);m.push(y)}return x0(m)}` and guanying 观影
//    (same shape via ljt). The lines exist — just not under douban.
//  Fix: detail(vodID:title:) falls back when /detail answers with
//  no list and the id is an aggregator id ("msearch:…"): it searches
//  the bundle's OTHER sites by the item's title (in parallel), takes
//  the first title match in /config order, and calls THAT site's
//  /detail for the play lines. The matched route is recorded on the
//  item (VideoItem.resolvedSiteAPI) so playLines calls /play there
//  too. The strict error style from v2.1.2 is kept: when the
//  fallback also fails, the error quotes the attempted route + body,
//  the original /detail raw reply, and the sites tried.
//
// v2.1.4 — ONE BUNDLE = MANY SOURCES. The 9280 bundle's /config
// returns 93 video sites (plus read/comic/music/pan groups), and
// Yingxia shows every one as an independently browsable source.
// YiPlayer used to collapse the whole bundle into ONE Source and
// switch sites behind a private siteKey, so only the default site
// (douban) was reachable. Now a bundle subscription expands into
// one Source per site (expandedSources()), each carrying its own
// route in Source.spider; the legacy siteKey path is kept only for
// the pre-expansion single source. Grouping comes from the bundle
// itself: each /config name is "Name|Tag" (55 of 57 spider metas in
// the bundle carry a "|", e.g. "玩偶|4K", "花卷|秒播"), so the tag
// after "|" is the group, else the config group
// (video/read/comic/music/pan). Yingxia's chip names (推荐/摸鱼/
// 蝴蝶/牛二/搜剧) occur ZERO times in the bundle — they are
// Yingxia's own grouping and are NOT copied here.
//
// TVBox JSON type 1 / type 4 sources are NOT handled here — see
// JsonSource below (same file, v1, URLSession + JSONDecoder only).
public struct CatSite {
    public var key: String        // e.g. "douban", "guanying" ("nodejs_" stripped)
    public var name: String       // display name: part of /config name before "|"
    public var group: String      // tag after "|" ("4K", "秒播", …) or the config
                                  // group ("video"/"read"/"comic"/"music"/"pan")
    public var api: String        // the site's own route, e.g. "/spider/douban/3"
    public var type: Int          // /config type: 3 = vod, 4 = push (not a site)
    public var searchable: Int    // 1 = searchable, 0 = not (config centre, …)

    /// A site is browsable content when it is a vod entry (type 3),
    /// searchable, and not a date-stamp marker. Excluded by evidence
    /// from the live 9280 /config and the bundle code: type 4 `push`
    /// (a push endpoint, not a site), searchable=0 `baseset`
    /// (配置|中心), and `gengxin` whose name is a date stamp
    /// ("日期:20261127" — and whose detail/search/play are stubs
    /// like douban's, see the header note).
    public var isContentSite: Bool {
        type == 3 && searchable == 1 && !name.hasPrefix("日期:")
    }

    /// Display name + tag from a /config entry name such as
    /// "玩偶 4K|4K", "花卷|秒播", "豆瓣|首页". Without "|", the whole
    /// name is the display name and the tag is the config group.
    public static func splitName(_ raw: String, configGroup: String) -> (name: String, group: String) {
        let parts = raw.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2 { return (parts[0], parts[1]) }
        return (raw.trimmingCharacters(in: .whitespaces), configGroup)
    }
}

public final class CatSource: SourceRunner {
    public let source: Source
    private let runtime: CatJSRuntime
    private let node = NodeHost.shared
    private var bundleText: String?
    /// True once loadBundle() has decided this is a Fastify server
    /// bundle: all calls go through NodeHost, never CatJSRuntime.
    private var isServerBundle = false
    /// The .md5-verified bundle file Node runs (Application Support).
    private var bundleFileURL: URL?
    private var profileDirURL: URL?
    /// Last detail payload, so playLines(for:) can resolve every line
    /// for an episode number from its playGroups (Node path).
    private var lastDetail: VideoItem?
    /// Sites the server bundle offers (from GET /config), best-effort.
    public private(set) var sites: [CatSite] = []

    /// The site inside the bundle that home/category/detail/search/play
    /// call. For an EXPANDED source this is the site's own route
    /// (Source.spider, e.g. "/spider/douban/3"), used verbatim. For a
    /// legacy single source it is derived from the stored siteKey.
    private var catPawOpen: String {
        if let spider = source.spider, spider.hasPrefix("/") { return spider }
        if let spider = source.spider, !spider.isEmpty { return "/spider/\(spider)" }
        let key = siteKey
        return key.hasPrefix("/") ? key : "/spider/\(key)"
    }

    /// The stored site for a legacy single source. v2.1.3 stored the
    /// full route ("/spider/douban/3") as the key, so a stored value
    /// starting with "/" is used verbatim; a bare key ("douban") is
    /// mapped to its site's route. A stored value that is no longer
    /// among the current sites (e.g. the bogus "video" v2.1.2 stored
    /// for the 9280 bundle, before grouped /config parsing existed)
    /// falls back to the first site instead of calling a route that
    /// does not exist. Expanded sources never read this: their route
    /// is fixed in Source.spider.
    public var siteKey: String {
        get {
            let stored = UserDefaults.standard.string(forKey: "yiplayer.cat.site.\(source.id)")
            if let stored {
                if stored.hasPrefix("/") { return stored }
                if let site = sites.first(where: { $0.key == stored }) { return site.api }
                return sites.first?.api ?? "/spider/douban/3"
            }
            return sites.first?.api ?? "/spider/douban/3"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "yiplayer.cat.site.\(source.id)")
        }
    }

    public init(source: Source, runtime: CatJSRuntime = CatJSRuntime()) {
        self.source = source
        self.runtime = runtime
    }

    // MARK: Bundle loading + .md5 verification
    public func loadBundle() async throws {
        // Only a ".md5" URL gets hash verification: fetch the .md5 file,
        // then the bundle at the same URL minus ".md5", and compare.
        // A plain ".js" URL is fetched directly — treating its own text
        // as an md5 checksum (the old behaviour) could never match.
        // A file:// URL (local .js import) is read from disk.
        // The download itself is shared (sharedBundleText): after
        // expansion, ~90 sources serve the same bundle, and each one
        // loading it separately would download the same 6 MB file 90
        // times on the first parallel search.
        let apiURL = source.api
        let bundleURL = apiURL.pathExtension == "md5" ? apiURL.deletingPathExtension() : apiURL
        let jsText = try await Self.sharedBundleText(
            bundleURL: bundleURL, md5URL: apiURL.pathExtension == "md5" ? apiURL : nil)
        guard !jsText.isEmpty else { throw SourceError.parse("猫源 bundle 为空") }
        bundleText = jsText

        // v2: a Fastify server bundle no longer stops here. It is
        // written to disk (MD5 already verified above) and started in
        // the embedded Node.js runtime; websiteBundle / Spider bundles
        // still go through the bounded JavaScriptCore host.
        if CatJSRuntime.detectKind(in: jsText) == .serverBundle {
            try await startServerBundle(jsText: jsText, originURL: bundleURL)
            return
        }
        isServerBundle = false
        try runtime.load(bundleText: jsText, sourceName: source.name)
    }

    /// One in-flight bundle download per bundle URL (v2.1.4). After
    /// expansion, ~90 sources serve the same bundle; without this, the
    /// first parallel search would download the same 6 MB file 90
    /// times. The shared task fetches the .md5, the bundle, verifies
    /// the hash, and every waiter gets the same text. The entry is
    /// removed when the task finishes (success or failure), so a later
    /// load re-downloads — a bundle updated server-side is never
    /// served stale from this cache.
    private static var bundleTextTasks: [String: Task<String, Error>] = [:]
    private static let bundleTextTasksLock = NSLock()

    private static func sharedBundleText(bundleURL: URL, md5URL: URL?) async throws -> String {
        bundleTextTasksLock.lock()
        if let existing = bundleTextTasks[bundleURL.absoluteString] {
            bundleTextTasksLock.unlock()
            return try await existing.value
        }
        let task = Task<String, Error> {
            if let md5URL {
                let md5Text = try await Self.fetchTextStatic(url: md5URL)
                let expected = md5Text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !expected.isEmpty else {
                    throw SourceError.parse(".md5 文件为空，无法校验 index.js")
                }
                let jsText = try await Self.fetchTextStatic(url: bundleURL)
                guard CatJSRuntime.md5Hex(of: jsText) == expected.lowercased() else {
                    throw SourceError.parse("index.js 的 MD5 与 .md5 文件不符，拒绝加载")
                }
                return jsText
            }
            return try await Self.fetchTextStatic(url: bundleURL)
        }
        bundleTextTasks[bundleURL.absoluteString] = task
        bundleTextTasksLock.unlock()
        do {
            let text = try await task.value
            bundleTextTasksLock.lock()
            bundleTextTasks[bundleURL.absoluteString] = nil
            bundleTextTasksLock.unlock()
            return text
        } catch {
            bundleTextTasksLock.lock()
            bundleTextTasks[bundleURL.absoluteString] = nil
            bundleTextTasksLock.unlock()
            throw error
        }
    }

    /// Fetch subscription/bundle text. file:// URLs (local imports) are
    /// read from disk; everything else goes through URLSession, which
    /// is also what the ATS setting in Info.plist governs.
    private func fetchText(url: URL) async throws -> String {
        try await Self.fetchTextStatic(url: url)
    }

    private static func fetchTextStatic(url: URL) async throws -> String {
        if url.isFileURL {
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else {
                throw SourceError.parse("无法读取本地文件：\(url.lastPathComponent)")
            }
            return text
        }
        let (text, _) = try await SubscriptionImporter.fetch(url: url)
        return text
    }

    /// Write a verified server bundle to disk and start it in Node.
    /// The bundle file lives under Application Support (NOT Documents:
    /// it is a verified download, not a user document).
    ///
    /// v2.1.4 — ONE FILE PER BUNDLE, NOT PER SOURCE. host.mjs keys
    /// its worker threads by bundle FILE PATH, so one file per source
    /// id would start one worker per expanded site — ~90 Fastify
    /// servers for the 9280 bundle. All sources of one bundle URL
    /// share one file (and one worker) instead; the directory is
    /// keyed by the MD5 of the bundle origin URL. The profile
    /// directory is shared too: a bundle's settings are per-bundle,
    /// not per-site. The file is rewritten only when its content
    /// actually differs, so 90 instances loading the same bundle do
    /// not rewrite the same 6 MB file 90 times.
    private func startServerBundle(jsText: String, originURL: URL) async throws {
        let dir = Self.bundleDirURL(for: originURL)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("index.js")
        if (try? String(contentsOf: file, encoding: .utf8)) != jsText {
            try jsText.write(to: file, atomically: true, encoding: .utf8)
        }
        let profile = dir.appendingPathComponent("profile", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        bundleFileURL = file
        profileDirURL = profile
        isServerBundle = true
        // Start Node (lazy, once per process) and ask the bundle for its
        // site list. A bundle that never answers /config still works:
        // siteKey falls back to "douban" (see the siteKey getter).
        // But a bundle that DOES answer /config and yields no usable
        // site is a real problem, not a fallback case: throw with the
        // raw answer, so the next device test shows what /config
        // actually returned instead of a blank page (v2.1.2's strict
        // parsing, applied to the site list itself).
        let configText = try? await node.config(bundle: file.path, api: originURL.absoluteString,
                                                profile: profile.path)
        if let configText {
            sites = Self.parseSiteEntries(from: configText)
            guard !sites.isEmpty else {
                throw SourceError.parse("猫源 /config 里没有可用的站点：\(String(configText.prefix(300)))")
            }
        }
    }

    /// Shared bundle directory for one bundle origin URL (v2.1.4).
    /// See startServerBundle: host.mjs keys workers by file path, so
    /// every source serving the same bundle URL must share this dir.
    private static func bundleDirURL(for originURL: URL) -> URL {
        let hash = CatJSRuntime.md5Hex(of: originURL.absoluteString)
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YiPlayer/cat/bundle-\(hash)", isDirectory: true)
    }

    /// All /config entries, across video/read/comic/music/pan, in
    /// bundle order. Each entry is {key, name, type, searchable,
    /// api}. The 9280 bundle's video group alone has 93 entries.
    /// Shapes, tried in order (v2.1.3, kept):
    ///  1. Grouped shape (the 9280 bundle):
    ///     {video:{sites:[...],danmuSearchUrl},read:{sites:[]},
    ///     comic:{sites:[]},music:{sites:[]},pan:{sites:[]},...} —
    ///     the entries of each group's `sites` array, video first.
    ///     NOTE: once a group is recognised (a dict with a "sites"
    ///     key, or an array), the shape IS grouped — even if every
    ///     group is empty, the dict-keyed fallback below must not
    ///     run, or it would turn the group names (video/read/...)
    ///     back into fake sites (exactly what v2.1.2 did: siteKey
    ///     became "video", /spider/video 404'd).
    ///  2. Top-level array under sites/list/sources/data:
    ///     {"sites": [{key,name}|{id,title}|{...,api}]} (old shape,
    ///     still accepted; group is "" there).
    ///  3. Dict keyed by site key: {"douban": {"name": ...}, ...}.
    ///     NOTE: this must stay LAST — on the grouped shape it would
    ///     otherwise turn the group names into fake sites.
    /// One entry's key: its `key` field with a "nodejs_" prefix
    /// stripped (e.g. nodejs_douban -> douban); its route is the
    /// `api` field when present (e.g. "/spider/douban/3"), because
    /// /config keys cannot be appended to /spider/. Duplicate routes
    /// are dropped, first occurrence wins.
    public static func parseSiteEntries(from text: String) -> [CatSite] {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var raw: [(entry: [String: Any], group: String)] = []
        if let dict = json as? [String: Any] {
            // Grouped shape first: fixed group order keeps the list
            // stable (video first); JSONSerialization gives no key
            // order, so unknown groups are appended sorted.
            let groups = ["video", "read", "comic", "music", "pan"]
                + dict.keys.filter { !["video", "read", "comic", "music", "pan"].contains($0) }.sorted()
            var grouped = false
            for group in groups {
                guard let value = dict[group] else { continue }
                if let groupDict = value as? [String: Any] {
                    if groupDict["sites"] != nil {
                        grouped = true
                        if let arr = groupDict["sites"] as? [[String: Any]] {
                            raw.append(contentsOf: arr.map { ($0, group) })
                        }
                    }
                } else if let arr = value as? [[String: Any]] {
                    grouped = true
                    raw.append(contentsOf: arr.map { ($0, group) })
                }
            }
            if !grouped {
                for key in ["sites", "list", "sources", "data"] {
                    if let arr = dict[key] as? [[String: Any]] {
                        raw = arr.map { ($0, "") }
                        break
                    }
                }
            }
            if raw.isEmpty && !grouped {
                // Dict keyed by site key: {"douban": {"name": ...}, ...}
                raw = dict.compactMap { (k, v) -> ([String: Any], String)? in
                    guard var d = v as? [String: Any] else { return nil }
                    d["key"] = d["key"] ?? k
                    return (d, "")
                }
            }
        } else if let arr = json as? [[String: Any]] {
            raw = arr.map { ($0, "") }
        }
        var seen = Set<String>()
        return raw.compactMap { (d, group) -> CatSite? in
            guard let rawKey = (d["key"] as? String) ?? (d["id"] as? String), !rawKey.isEmpty else { return nil }
            let key = rawKey.hasPrefix("nodejs_") ? String(rawKey.dropFirst("nodejs_".count)) : rawKey
            let api: String
            if let apiField = d["api"] as? String, !apiField.trimmingCharacters(in: .whitespaces).isEmpty {
                let trimmed = apiField.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("/") { api = trimmed }
                else if trimmed.hasPrefix("spider/") { api = "/\(trimmed)" }
                else { api = "/spider/\(trimmed)" }
            } else {
                api = "/spider/\(key)"
            }
            guard seen.insert(api).inserted else { return nil }
            let rawName = (d["name"] as? String) ?? (d["title"] as? String) ?? key
            let (name, tag) = CatSite.splitName(rawName, configGroup: group)
            return CatSite(
                key: key,
                name: name,
                group: tag,
                api: api,
                type: (d["type"] as? Int) ?? 3,
                searchable: (d["searchable"] as? Int) ?? 1
            )
        }
    }

    /// Legacy shape kept for the Settings picker: (key, display name).
    /// NOTE: the key here is the site's ROUTE (e.g. "/spider/douban/3"),
    /// matching what v2.1.3 stored in UserDefaults — not the bare key.
    public static func parseSites(from text: String) -> [(key: String, name: String)] {
        parseSiteEntries(from: text).map { (key: $0.api, name: $0.name) }
    }

    /// One Source per content site in this bundle (v2.1.4). Used by
    /// Settings to expand a single-source bundle subscription into
    /// many independently browsable sources, like Yingxia. Non-content
    /// entries (push endpoints, the config centre, the date-stamp
    /// marker) are left out — see CatSite.isContentSite. The expanded
    /// sources keep the subscription id, so the subscription keeps
    /// owning them; their own ids are "cat-<sub>-<route>". The douban
    /// site is marked not searchable: its search() is a stub returning
    /// {} (see the header note), so letting SearchView call it would
    /// only ever paint a parse error; it stays browsable in Discover
    /// (its home/category are real).
    public func expandedSources() async throws -> [Source] {
        try await ensureLoaded()
        return sites.filter(\.isContentSite).map { site in
            let slug = site.api
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .replacingOccurrences(of: "/", with: "-")
            return Source(
                id: "cat-\(source.subscriptionID)-\(slug)",
                name: site.name,
                kind: .cat,
                api: source.api,
                spider: site.api,
                isSearchable: site.key == "douban" ? false : site.searchable == 1,
                isChangeable: false,
                subscriptionID: source.subscriptionID,
                group: site.group
            )
        }
    }

    /// What kind of bundle did we actually get? (Used by the UI + fallback.)
    public var bundleKind: CatJSRuntime.BundleKind {
        runtime.bundleKind
    }

    // MARK: SourceRunner — server bundles via NodeHost, everything
    // else via the bounded JavaScriptCore host (unchanged from v1).
    public func home(filter: [String: String]) async throws -> [VideoItem] {
        try await ensureLoaded()
        if isServerBundle { return try await nodeItems(params: [:]) }
        return try await runtime.home(source: source, filter: filter)
    }

    public func categories() async throws -> [(id: String, name: String)] {
        // The bundle's /home answer carries its classes
        // ({class: [{type_id, type_name}]}); reuse it, cached by the
        // home() call below so DiscoverView does not fetch twice.
        if isServerBundle {
            try await ensureLoaded()
            let text = try await nodeCall(params: [:])
            guard let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let classes = json["class"] as? [[String: Any]] else { return [] }
            return classes.compactMap { d in
                guard let id = d["type_id"] as? String,
                      let name = d["type_name"] as? String else { return nil }
                return (id, name)
            }
        }
        // websiteBundle / Spider path: the bounded JS host exposes no
        // class list, so keep the v1 category ids (555.py reference set).
        return [("1", "电影"), ("2", "连续剧"), ("3", "综艺纪录"), ("4", "动漫"), ("126", "短剧")]
    }

    public func category(typeID: String, page: Int) async throws -> (items: [VideoItem], pageCount: Int) {
        try await ensureLoaded()
        if isServerBundle {
            let text = try await nodeCall(params: ["t": typeID, "pg": "\(page)"])
            return (try items(from: text, route: "/category"), pageCount(from: text) ?? page)
        }
        return try await runtime.category(source: source, typeID: typeID, page: page)
    }

    public func category(typeID: String, page: Int, filter: [String: String]) async throws -> (items: [VideoItem], pageCount: Int) {
        // Cat bundles take no window filter; the filter is accepted and
        // ignored so DiscoverView can call one method for every kind.
        _ = filter
        return try await category(typeID: typeID, page: page)
    }

    public func detail(vodID: String) async throws -> VideoItem {
        try await detail(vodID: vodID, title: nil)
    }

    /// Detail with the aggregator fallback (v2.1.4). The item's own
    /// /detail is tried first, exactly as before. If the bundle
    /// answers but with no list (the douban stub returns {}), and the
    /// id is an aggregator id ("msearch:<douban id>"), the lines are
    /// resolved by searching the bundle's other sites by title.
    public func detail(vodID: String, title: String?) async throws -> VideoItem {
        try await ensureLoaded()
        if !isServerBundle {
            return try await runtime.detail(source: source, vodID: vodID)
        }
        var rawDetail = ""
        do {
            rawDetail = try await nodeCall(params: ["ids": vodID])
            if let item = try items(from: rawDetail, route: "/detail").first {
                lastDetail = item
                return item
            }
            throw SourceError.noResult
        } catch {
            var isEmptyDetail = false
            if let sourceError = error as? SourceError {
                switch sourceError {
                case .parse(let message): isEmptyDetail = message.contains("没有 list")
                case .noResult: isEmptyDetail = true
                default: isEmptyDetail = false
                }
            }
            guard isEmptyDetail, vodID.hasPrefix("msearch:"),
                  let title, !title.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw error
            }
            return try await aggregatorDetail(vodID: vodID, title: title, rawDetail: rawDetail)
        }
    }

    /// Aggregator fallback (v2.1.4). Searches up to 8 of the bundle's
    /// other content sites by title, in parallel, takes the title
    /// matches in /config order, and calls each matched site's /detail
    /// in that order until one returns lines. The matched site's route
    /// is recorded on the item (resolvedSiteAPI) so playLines calls
    /// /play there. Evidence: the 9280 bundle's douban spider has
    /// `async detail(){return{}}, async play(){return{}}` while every
    /// other spider (wogg 玩偶, guanying 观影, …) implements detail by
    /// fetching real MacCMS JSON — so the lines exist, just not under
    /// douban. v2.1.3's live test proved the rest: search works and
    /// the search list item already carries poster/title/score, so
    /// only the lines are missing.
    private func aggregatorDetail(vodID: String, title: String, rawDetail: String) async throws -> VideoItem {
        let tried = Array(sites.filter { $0.isContentSite && $0.api != catPawOpen }.prefix(8))
        let query = Self.normalizedTitle(title)
        guard !tried.isEmpty else {
            throw SourceError.parse(
                "猫源 /detail 空返回：\(catPawOpen) 是聚合站，没有详情接口；" +
                "按片名“\(title)”没有可搜的兄弟站。" +
                "本次 /detail 请求：route=/detail body={id: \(vodID)}，" +
                "原始返回：\(String(rawDetail.prefix(300)))")
        }
        guard let bundlePath = bundleFileURL?.path, let profilePath = profileDirURL?.path else {
            throw SourceError.noResult
        }
        let apiString = source.api.absoluteString
        let sourceID = source.id

        // Search the sibling sites in parallel; keep the title matches
        // in /config order (deterministic, not completion order). The
        // task group captures only local values, never self: the
        // static searchSite helper does the Node call. Each site gets
        // 12 s — a site whose upstream hangs would otherwise hold the
        // whole fallback for the 60 s Node request timeout (a real
        // 4K site did hang for 45 s+ in the local bundle test).
        let matches = await withTaskGroup(of: (Int, CatSite, VideoItem?).self) { group in
            for (index, site) in tried.enumerated() {
                group.addTask {
                    let hits = await Self.searchSiteWithTimeout(
                        bundle: bundlePath, profile: profilePath, api: apiString,
                        route: site.api, keyword: title, sourceID: sourceID)
                    let match = hits?.first { hit in
                        let name = Self.normalizedTitle(hit.title)
                        return !name.isEmpty && (name == query
                            || name.contains(query) || query.contains(name))
                    }
                    return (index, site, match)
                }
            }
            var found: [(Int, CatSite, VideoItem)] = []
            for await (index, site, match) in group {
                if let match { found.append((index, site, match)) }
            }
            return found.sorted { $0.0 < $1.0 }
        }

        var lastError: Error?
        for (_, site, hit) in matches {
            do {
                let text = try await nodeCall(params: ["ids": hit.id], route: site.api)
                // A matched detail with no play lines is useless — the
                // user would see the same empty detail page. (Seen
                // live: guanying's /detail for 哪吒 returns full
                // metadata but empty vod_play_from/vod_play_url.)
                // Keep trying the next matched site instead.
                guard let found = try items(from: text, route: "/detail").first,
                      !found.playGroups.isEmpty else { continue }
                var item = found
                item.resolvedSiteAPI = site.api
                if item.title.isEmpty { item.title = title }
                lastDetail = item
                return item
            } catch {
                lastError = error
                continue
            }
        }
        if matches.isEmpty {
            throw SourceError.parse(
                "猫源 /detail 空返回：\(catPawOpen) 是聚合站，没有详情接口；" +
                "按片名“\(title)”在 \(tried.count) 个站里搜了一圈也没找到可播线路" +
                "（试了：\(tried.map(\.name).joined(separator: "、"))）。" +
                "本次 /detail 请求：route=/detail body={id: \(vodID)}，" +
                "原始返回：\(String(rawDetail.prefix(300)))")
        }
        let first = matches[0]
        throw SourceError.parse(
            "猫源 /detail 空返回：\(catPawOpen) 是聚合站，没有详情接口；" +
            "按片名“\(title)”在 \(tried.count) 个站里找到“\(first.2.title)”" +
            "（\(first.1.name)），但调它的 /detail 没拿到线路" +
            "（最后错误：\(lastError?.localizedDescription ?? "无 list")）。" +
            "本次 /detail 请求：route=/detail body={id: \(vodID)}，" +
            "原始返回：\(String(rawDetail.prefix(300)))")
    }

    /// Title comparison key: lowercase, no whitespace or punctuation.
    /// "巴黎绽放的星辰" still matches "巴黎绽放的星辰 (2025)" once
    /// the latter's brackets and year are stripped away.
    private static func normalizedTitle(_ title: String) -> String {
        title.lowercased()
            .unicodeScalars
            .filter { !CharacterSet.whitespacesAndNewlines.contains($0)
                && !CharacterSet.punctuationCharacters.contains($0) }
            .map { Character($0) }
            .reduce(into: "") { $0.append($1) }
    }

    /// One sibling site's /search, without touching instance state
    /// (used inside the fallback's task group, which must not capture
    /// self). The route is the site's own api ("/spider/<key>/<type>").
    /// A failed search is nil, not an error — one dead site must not
    /// fail the whole fallback.
    private static func searchSite(bundle: String, profile: String, api: String,
                                   route: String, keyword: String, sourceID: String) async throws -> [VideoItem] {
        let text = try await NodeHost.shared.call(
            bundle: bundle, api: api, profile: profile,
            params: ["wd": keyword, "pg": "1", "catPawOpen": route])
        return try strictItems(from: text, route: "/search", sourceID: sourceID)
    }

    /// searchSite with a 12 s timeout. A site whose upstream hangs
    /// would otherwise hold the whole fallback for the 60 s Node
    /// request timeout (one 4K site hung for 45 s+ in the local
    /// bundle test). A timed-out site is skipped like a failed one.
    private static func searchSiteWithTimeout(bundle: String, profile: String, api: String,
                                              route: String, keyword: String, sourceID: String) async -> [VideoItem]? {
        await withTaskGroup(of: [VideoItem]?.self) { group in
            group.addTask { try? await Self.searchSite(bundle: bundle, profile: profile, api: api, route: route, keyword: keyword, sourceID: sourceID) }
            group.addTask {
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    public func search(keyword: String, page: Int) async throws -> [VideoItem] {
        try await ensureLoaded()
        if isServerBundle { return try await nodeItems(params: ["wd": keyword, "pg": "\(page)"], route: "/search") }
        return try await runtime.search(source: source, keyword: keyword, page: page)
    }

    public func playLines(for episode: Episode) async throws -> [PlayLine] {
        try await ensureLoaded()
        if isServerBundle { return try await nodePlayLines(for: episode) }
        return try await runtime.playLines(source: source, episode: episode)
    }

    private func ensureLoaded() async throws {
        if bundleText == nil && bundleFileURL == nil { try await loadBundle() }
    }

    // MARK: NodeHost call helpers (server-bundle path only)
    /// Call host.mjs /call on one site route. `route` defaults to
    /// this source's own route (catPawOpen); the detail fallback
    /// passes sibling sites' routes here, and playLines passes the
    /// route that served the detail (resolvedSiteAPI).
    private func nodeCall(params: [String: Any], route: String? = nil) async throws -> String {
        guard let bundle = bundleFileURL?.path, let profile = profileDirURL?.path else {
            throw SourceError.parse("猫源 bundle 未加载")
        }
        var full = params
        full["catPawOpen"] = route ?? catPawOpen
        return try await node.call(bundle: bundle, api: source.api.absoluteString,
                                   profile: profile, params: full)
    }

    private func items(from text: String) -> [VideoItem] {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["list"] as? [[String: Any]] else { return [] }
        return list.compactMap { JsonSource.videoItem(from: $0, sourceID: source.id) }
    }

    /// Strict list parse, for /category, /search and /detail (server
    /// bundles only). A JSON answer WITH a "list" key — even an empty
    /// one — is a genuine answer: a category or a search can
    /// legitimately be empty, and that stays a silent empty state.
    /// An answer WITHOUT a "list" key means the bundle answered
    /// something else entirely (wrong route, wrong request fields,
    /// an error object, HTML) — throw with the raw text, so the next
    /// device test shows the real reason instead of a blank page.
    /// v2.1.1 returned [] for all of these, so the 9280 tab showed
    /// "这个分类没有内容" with no error and no diagnostic, and search
    /// "奥德赛" showed nothing at all — the Node response never
    /// reached the UI. home() deliberately keeps the lenient parse
    /// above: /home may legitimately be classes-only, and HomeView
    /// already falls through to the next source on an empty home.
    private func items(from text: String, route: String) throws -> [VideoItem] {
        try Self.strictItems(from: text, route: route, sourceID: source.id)
    }

    /// The strict parse as a static helper, so the fallback's task
    /// group can use it without capturing self.
    private static func strictItems(from text: String, route: String, sourceID: String) throws -> [VideoItem] {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SourceError.parse("猫源\(route)返回了无法解析的结果：\(String(text.prefix(300)))")
        }
        guard let list = json["list"] as? [[String: Any]] else {
            throw SourceError.parse("猫源\(route)返回的结果里没有 list：\(String(text.prefix(300)))")
        }
        return list.compactMap { JsonSource.videoItem(from: $0, sourceID: sourceID) }
    }

    private func nodeItems(params: [String: Any]) async throws -> [VideoItem] {
        items(from: try await nodeCall(params: params))
    }

    private func nodeItems(params: [String: Any], route: String) async throws -> [VideoItem] {
        try items(from: try await nodeCall(params: params), route: route)
    }

    private func pageCount(from text: String) -> Int? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["pagecount"] as? Int
    }

    /// Resolve every line for one episode via the bundle's /play route:
    /// the play id is the token from vod_play_url ("<token>" or
    /// "<token>@@<line_id>"); the bundle answers {"url": <m3u8>,
    /// "header": {...}} or a bare URL string.
    private func nodePlayLines(for episode: Episode) async throws -> [PlayLine] {
        guard let detail = lastDetail, detail.id == episode.vodID else {
            if let url = episode.playURL {
                return [PlayLine(id: episode.id, name: "线路 1", url: url)]
            }
            throw SourceError.noResult
        }
        var lines: [PlayLine] = []
        for (lineIndex, group) in detail.playGroups.enumerated() {
            let entryIndex = episode.number - 1
            guard entryIndex >= 0, entryIndex < group.count else { continue }
            let entry = group[entryIndex]
            guard let dollar = entry.firstIndex(of: "$") else { continue }
            let playID = String(entry[entry.index(after: dollar)...])
                .trimmingCharacters(in: .whitespaces)
            guard !playID.isEmpty else { continue }
            let name = detail.playFrom.indices.contains(lineIndex)
                ? detail.playFrom[lineIndex] : "线路 \(lineIndex + 1)"
            // /play must go to the site that served this detail — for a
            // fallback item that is the matched site, not the douban route.
            let text = try await nodeCall(params: ["play": playID, "flag": name],
                                          route: detail.resolvedSiteAPI)
            guard let url = Self.playURL(from: text) else { continue }
            let headers = Self.playHeaders(from: text)
            lines.append(PlayLine(id: "\(episode.vodID)-\(lineIndex)-\(episode.number)",
                                  name: name, url: url, headers: headers))
        }
        guard !lines.isEmpty else { throw SourceError.noResult }
        return lines
    }

    /// Parse a /play answer: {"url": ...} / {"playUrl": ...} /
    /// {"data": {"url": ...}} / a bare URL string. Anything else -> nil.
    static func playURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http"), let url = URL(string: trimmed) { return url }
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let candidates = [json["url"], json["playUrl"], (json["data"] as? [String: Any])?["url"]]
        for candidate in candidates {
            if let s = candidate as? String, let url = URL(string: s), !s.isEmpty { return url }
        }
        return nil
    }

    static func playHeaders(from text: String) -> [String: String] {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let headers = json["header"] as? [String: String] else { return [:] }
        return headers
    }
}

// MARK: - JsonSource (TVBox JSON type 1 / type 4)
//
// The plain, well-understood path. A type 1/4 source answers
//   { "class": [...], "list": [vod_*] }  (home/category)
//   { "list": [vod_* with vod_play_from / vod_play_url] }  (detail)
//   { "list": [...] }  (search)
// with vod_play_url entries of the form "Name$playid#Name$playid".
// Relative API URLs are resolved against the subscription URL
// (SubscriptionImporter.resolve). No JS, no Python.
public final class JsonSource: SourceRunner {
    public let source: Source
    /// Last detail payload, so playLines(for:) can resolve every line
    /// for an episode number from its playGroups.
    private var lastDetail: VideoItem?

    public init(source: Source) { self.source = source }

    private func get(ac: String, query: [String: String] = [:]) async throws -> [String: Any] {
        var components = URLComponents(url: source.api, resolvingAgainstBaseURL: true)
        var items = (components?.queryItems ?? []) + query.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "ac", value: ac))
        components?.queryItems = items
        guard let url = components?.url else { throw SourceError.parse("API 地址无效") }
        var request = URLRequest(url: url)
        request.setValue("YiPlayer/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SourceError.network("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SourceError.parse("JSON 解析失败")
        }
        return json
    }

    private func items(from json: [String: Any]) -> [VideoItem] {
        guard let list = json["list"] as? [[String: Any]] else { return [] }
        return list.compactMap { JsonSource.videoItem(from: $0, sourceID: source.id) }
    }

    static func videoItem(from d: [String: Any], sourceID: String) -> VideoItem? {
        guard let id = (d["vod_id"] as? CustomStringConvertible)?.description,
              let title = d["vod_name"] as? String else { return nil }
        let pic = (d["vod_pic"] as? String).flatMap { URL(string: $0) }
        // vod_play_from lines are "$$$"-joined (NOT "$"-joined: "$" also
        // separates "Name$playid" inside vod_play_url).
        let playFrom = ((d["vod_play_from"] as? String) ?? "")
            .components(separatedBy: "$$$").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let playGroups: [[String]] = ((d["vod_play_url"] as? String) ?? "")
            .components(separatedBy: "$$$")
            .map { $0.components(separatedBy: "#").filter { !$0.isEmpty } }
            .filter { !$0.isEmpty }
        // Episodes: one per entry on the longest line, so the grid shows
        // episode numbers once; playLines(for:) resolves every line for
        // that number from playGroups.
        let longest = playGroups.max(by: { $0.count < $1.count }) ?? []
        let episodes: [Episode] = longest.enumerated().map { index, entry in
            let (name, playID) = Self.splitPlayEntry(entry)
            let playURL = playID.flatMap { URL(string: $0) }
                .flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil }
            return Episode(id: "\(id)-0-\(index + 1)", vodID: id, lineIndex: 0,
                           number: index + 1, name: name.isEmpty ? "第\(index + 1)集" : name,
                           playURL: playURL)
        }
        return VideoItem(
            id: id, sourceID: sourceID, title: title, coverURL: pic,
            year: (d["vod_year"] as? CustomStringConvertible)?.description,
            area: d["vod_area"] as? String,
            remarks: d["vod_remarks"] as? String,
            typeName: d["vod_type_name"] as? String,
            actors: ((d["vod_actor"] as? String) ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            director: d["vod_director"] as? String,
            content: d["vod_content"] as? String,
            mediaType: .unknown, playFrom: playFrom, episodes: episodes,
            playGroups: playGroups)
    }

    /// Split one "Name$playid" entry at the FIRST "$".
    private static func splitPlayEntry(_ entry: String) -> (name: String, playID: String?) {
        guard let dollar = entry.firstIndex(of: "$") else { return (entry, nil) }
        let name = String(entry[..<dollar]).trimmingCharacters(in: .whitespaces)
        let playID = String(entry[entry.index(after: dollar)...]).trimmingCharacters(in: .whitespaces)
        return (name, playID.isEmpty ? nil : playID)
    }

    public func home(filter: [String: String]) async throws -> [VideoItem] {
        items(from: try await get(ac: "list", query: filter))
    }

    public func category(typeID: String, page: Int) async throws -> (items: [VideoItem], pageCount: Int) {
        let json = try await get(ac: "list", query: ["t": typeID, "pg": "\(page)"])
        let count = (json["pagecount"] as? Int) ?? page
        return (items(from: json), count)
    }

    public func detail(vodID: String) async throws -> VideoItem {
        let json = try await get(ac: "detail", query: ["ids": vodID])
        guard let item = items(from: json).first else { throw SourceError.noResult }
        lastDetail = item
        return item
    }

    public func search(keyword: String, page: Int) async throws -> [VideoItem] {
        // MacCMS search action is ac=vid (wd=keyword); ac=list ignores wd.
        items(from: try await get(ac: "vid", query: ["wd": keyword, "pg": "\(page)"]))
    }

    public func playLines(for episode: Episode) async throws -> [PlayLine] {
        // Resolve every line for this episode number from the last detail
        // payload's playGroups. A playid that is not a direct http(s) URL
        // (e.g. a token the spider must resolve) is skipped honestly —
        // JsonSource cannot resolve it, and inventing a URL would be worse.
        if let detail = lastDetail, detail.id == episode.vodID {
            var lines: [PlayLine] = []
            for (lineIndex, group) in detail.playGroups.enumerated() {
                let entryIndex = episode.number - 1
                guard entryIndex >= 0, entryIndex < group.count else { continue }
                let (_, playID) = Self.splitPlayEntry(group[entryIndex])
                guard let playID, let url = URL(string: playID),
                      url.scheme?.hasPrefix("http") == true else { continue }
                let name = detail.playFrom.indices.contains(lineIndex)
                    ? detail.playFrom[lineIndex] : "线路 \(lineIndex + 1)"
                lines.append(PlayLine(id: "\(episode.vodID)-\(lineIndex)-\(episode.number)",
                                      name: name, url: url))
            }
            if !lines.isEmpty { return lines }
        }
        // Fallback: a bare episode that already carries a direct playURL.
        if let url = episode.playURL {
            return [PlayLine(id: episode.id, name: "线路 1", url: url)]
        }
        throw SourceError.noResult
    }
}
