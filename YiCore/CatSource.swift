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
//     lists its sites; the user picks one in Settings (default: the
//     first site /config lists, else "douban" — the 9280 bundle's
//     SOURCE_ORDER starts there).
//     v2.1.3: the 9280 bundle is a CatVodSpiderios STANDALONE server,
//     not an embeddable CatPawOpen bundle — it has no exports.start
//     (only dead-code module.exports) and autostarts only as
//     `node index.js` with no catServerFactory (see worker.mjs).
//     Its /config is grouped: {video:{sites:[...]},read:{sites:[]},
//     comic:{...},music:{...},pan:{...}}; each site's `api` field
//     ("/spider/<key>/<type>") is the route, because its keys are
//     `nodejs_<key>` and cannot be appended to /spider/.
//
// The test URL https://9280.kstore.vip/cat/index.js.md5 returns ONE line:
//   d8e69da8c37a29afe50fdc8de9dbf268
// That is the MD5 checksum of index.js, NOT the bundle itself.
// The bundle at https://9280.kstore.vip/cat/index.js (17,087 lines) is a
// CatVodSpiderios STANDALONE Fastify server bundle — async queues,
// Fastify server code, an Ott config with alist/netdisk sites, a danmu
// module (@dan-uni/dan-any 2.3.9), SOURCE_ORDER "douban,360,renren,
// hanjutv". It is NOT the aaaaa2780009/cat-bundle build (65,702 lines,
// first line "// ====慕猫源", defines globalThis.websiteBundle), and
// NOT an embeddable CatPawOpen bundle: no exports.start, autostart
// only as `node index.js` (v2.1.3: worker.mjs standalone mode).
//
// TVBox JSON type 1 / type 4 sources are NOT handled here — see
// JsonSource below (same file, v1, URLSession + JSONDecoder only).
public final class CatSource: SourceRunner {
    public let source: Source
    private let runtime: CatJSRuntime
    private let node = NodeHost.shared
    private var bundleText: String?
    private var expectedMD5: String?
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
    public private(set) var sites: [(key: String, name: String)] = []

    /// The site inside the bundle that home/category/detail/search/play
    /// call. Persisted per source; defaults to the first site /config
    /// lists, else "douban" (the 9280 bundle's SOURCE_ORDER starts
    /// there). A stored value that is no longer among the current
    /// sites (e.g. the bogus "video" v2.1.2 stored for the 9280
    /// bundle, before grouped /config parsing existed) falls back
    /// to the first site instead of calling a route that does not
    /// exist.
    public var siteKey: String {
        get {
            let stored = UserDefaults.standard.string(forKey: "yiplayer.cat.site.\(source.id)")
            if let stored, !sites.isEmpty, !sites.contains(where: { $0.key == stored }) {
                return sites[0].key
            }
            return stored ?? sites.first?.key ?? "douban"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "yiplayer.cat.site.\(source.id)")
        }
    }

    public init(source: Source, runtime: CatJSRuntime = CatJSRuntime()) {
        self.source = source
        self.runtime = runtime
    }

    /// The route host.mjs calls for this site. Usually
    /// "/spider/<siteKey>", but /config entries that carry their own
    /// `api` field (e.g. "/spider/douban/3" from the 9280 bundle)
    /// are stored as the key itself, and are used verbatim.
    private var catPawOpen: String {
        siteKey.hasPrefix("/") ? siteKey : "/spider/\(siteKey)"
    }

    // MARK: Bundle loading + .md5 verification
    public func loadBundle() async throws {
        // Only a ".md5" URL gets hash verification: fetch the .md5 file,
        // then the bundle at the same URL minus ".md5", and compare.
        // A plain ".js" URL is fetched directly — treating its own text
        // as an md5 checksum (the old behaviour) could never match.
        // A file:// URL (local .js import) is read from disk.
        let apiURL = source.api
        let bundleURL: URL
        if apiURL.pathExtension == "md5" {
            bundleURL = apiURL.deletingPathExtension()
            let md5Text = try await fetchText(url: apiURL)
            expectedMD5 = md5Text.trimmingCharacters(in: .whitespacesAndNewlines)
            let jsText = try await fetchText(url: bundleURL)
            guard let expected = expectedMD5, !expected.isEmpty else {
                throw SourceError.parse(".md5 文件为空，无法校验 index.js")
            }
            guard CatJSRuntime.md5Hex(of: jsText) == expected.lowercased() else {
                throw SourceError.parse("index.js 的 MD5 与 .md5 文件不符，拒绝加载")
            }
            bundleText = jsText
        } else {
            bundleURL = apiURL
            bundleText = try await fetchText(url: bundleURL)
        }
        guard let jsText = bundleText else { throw SourceError.parse("猫源 bundle 为空") }

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

    /// Fetch subscription/bundle text. file:// URLs (local imports) are
    /// read from disk; everything else goes through URLSession, which
    /// is also what the ATS setting in Info.plist governs.
    private func fetchText(url: URL) async throws -> String {
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
    /// it is a verified download, not a user document) and is
    /// overwritten on every load, so a changed .md5 always wins.
    private func startServerBundle(jsText: String, originURL: URL) async throws {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YiPlayer/cat/\(source.id)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("index.js")
        try jsText.write(to: file, atomically: true, encoding: .utf8)
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
            sites = Self.parseSites(from: configText)
            guard !sites.isEmpty else {
                throw SourceError.parse("猫源 /config 里没有可用的站点：\(String(configText.prefix(300)))")
            }
        }
    }

    /// Best-effort site list from a bundle's GET /config answer.
    /// Shapes, tried in order (v2.1.3):
    ///  1. Top-level array under sites/list/sources/data:
    ///     {"sites": [{key,name}|{id,title}|{...,api}]} (old shape,
    ///     still accepted).
    ///  2. Grouped shape (the 9280 bundle):
    ///     {video:{sites:[...],danmuSearchUrl},read:{sites:[]},
    ///     comic:{sites:[]},music:{sites:[]},pan:{sites:[]},...} —
    ///     the entries of each group's `sites` array, video first.
    ///  3. Dict keyed by site key: {"douban": {"name": ...}, ...}.
    ///     NOTE: this must stay LAST — on the grouped shape it would
    ///     otherwise turn the group names (video/read/comic/...) into
    ///     fake sites, which is exactly what v2.1.2 did (siteKey
    ///     became "video", /spider/video 404'd).
    /// One entry's key: its `api` field when present — the full route
    /// (e.g. "/spider/douban/3"), because /config keys are
    /// `nodejs_<key>` (e.g. nodejs_douban) and cannot be appended to
    /// /spider/; else its key/id with a "nodejs_" prefix stripped.
    /// Duplicate keys are dropped, first occurrence wins.
    static func parseSites(from text: String) -> [(key: String, name: String)] {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var raw: [[String: Any]] = []
        if let dict = json as? [String: Any] {
            for key in ["sites", "list", "sources", "data"] {
                if let arr = dict[key] as? [[String: Any]] { raw = arr; break }
            }
            if raw.isEmpty {
                // Grouped shape: {video:{sites:[...]},read:{sites:[]},...}
                // JSONSerialization gives no key order, so walk the
                // groups in a fixed preference order, video first.
                // Once a group is recognised (a dict with a "sites"
                // key, or an array), the shape IS grouped — even if
                // every group is empty, the dict-keyed fallback below
                // must not run, or it would turn the group names
                // (video/read/...) back into fake sites.
                let groups = ["video", "read", "comic", "music", "pan"]
                    + dict.keys.filter { !["video", "read", "comic", "music", "pan"].contains($0) }.sorted()
                var grouped = false
                for group in groups {
                    guard let value = dict[group] else { continue }
                    if let groupDict = value as? [String: Any] {
                        // A dict with a "sites" key IS a group, even if
                        // its entries turn out unparsable — the shape
                        // is grouped, so the fallback below must not
                        // misread the group name as a site.
                        if groupDict["sites"] != nil {
                            grouped = true
                            if let arr = groupDict["sites"] as? [[String: Any]] {
                                raw.append(contentsOf: arr)
                            }
                        }
                    } else if let arr = value as? [[String: Any]] {
                        grouped = true
                        raw.append(contentsOf: arr)
                    }
                }
                if !grouped {
                    // Dict keyed by site key: {"douban": {"name": ...}, ...}
                    raw = dict.compactMap { (k, v) -> [String: Any]? in
                        guard var d = v as? [String: Any] else { return nil }
                        d["key"] = d["key"] ?? k
                        return d
                    }
                }
            }
        } else if let arr = json as? [[String: Any]] {
            raw = arr
        }
        var seen = Set<String>()
        return raw.compactMap { d -> (key: String, name: String)? in
            let key: String
            if let api = d["api"] as? String, !api.trimmingCharacters(in: .whitespaces).isEmpty {
                let trimmed = api.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("/") { key = trimmed }
                else if trimmed.hasPrefix("spider/") { key = "/\(trimmed)" }
                else { key = "/spider/\(trimmed)" }
            } else if let rawKey = (d["key"] as? String) ?? (d["id"] as? String), !rawKey.isEmpty {
                key = rawKey.hasPrefix("nodejs_") ? String(rawKey.dropFirst("nodejs_".count)) : rawKey
            } else {
                return nil
            }
            guard seen.insert(key).inserted else { return nil }
            let name = (d["name"] as? String) ?? (d["title"] as? String) ?? key
            return (key, name)
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
        try await ensureLoaded()
        if isServerBundle {
            let text = try await nodeCall(params: ["ids": vodID])
            guard let item = try items(from: text, route: "/detail").first else { throw SourceError.noResult }
            lastDetail = item
            return item
        }
        return try await runtime.detail(source: source, vodID: vodID)
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
    private func nodeCall(params: [String: Any]) async throws -> String {
        guard let bundle = bundleFileURL?.path, let profile = profileDirURL?.path else {
            throw SourceError.parse("猫源 bundle 未加载")
        }
        var full = params
        full["catPawOpen"] = catPawOpen
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
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SourceError.parse("猫源\(route)返回了无法解析的结果：\(String(text.prefix(300)))")
        }
        guard let list = json["list"] as? [[String: Any]] else {
            throw SourceError.parse("猫源\(route)返回的结果里没有 list：\(String(text.prefix(300)))")
        }
        return list.compactMap { JsonSource.videoItem(from: $0, sourceID: source.id) }
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
            let text = try await nodeCall(params: ["play": playID, "flag": name])
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
