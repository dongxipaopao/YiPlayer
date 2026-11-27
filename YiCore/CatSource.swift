import Foundation

// MARK: - CatSource
// A CatVod JS ("cat") source, executed by CatJSRuntime (JavaScriptCore).
//
// LIMITATION — read this before expecting the 9280 test bundle to "just work":
// The test URL https://9280.kstore.vip/cat/index.js.md5 returns ONE line:
//   d8e69da8c37a29afe50fdc8de9dbf268
// That is the MD5 checksum of index.js, NOT the bundle itself.
// The bundle at https://9280.kstore.vip/cat/index.js (17,087 lines, fetched
// 2026-11-27) is a CatPawOpen-style Fastify SERVER bundle — async queues,
// Fastify server code, an Ott config with alist/netdisk sites, a danmu
// module (@dan-uni/dan-any 2.3.9), SOURCE_ORDER "douban,360,renren,hanjutv".
// It is NOT the aaaaa2780009/cat-bundle build (65,702 lines, first line
// "// ====慕猫源", defines globalThis.websiteBundle) and it contains no
// "websiteBundle" / "ALLOWED_SOURCES" marker.
//
// So v1 does this, in order:
//  1. Fetch the .md5 file, keep the expected hash.
//  2. Fetch index.js at the same URL minus ".md5", verify its MD5 matches.
//     (MD5 is computed with CryptoKit Insecure.MD5 — it is a version
//     checksum here, not a security boundary.)
//  3. Hand the bundle to CatJSRuntime. If the runtime reports that the
//     bundle is a server bundle (no websiteBundle / no Spider export),
//     CatSource does NOT execute it and does NOT pretend playback works:
//     loadBundle() throws a notSupported error naming the limitation and
//     the bundle's own SOURCE_ORDER (douban,360,renren,hanjutv).
//     Turning that SOURCE_ORDER into four playable sources is NOT
//     implemented in v1 (those four are themselves JS sites that need
//     a runtime) — see BUILD_NOTES.md.
//  4. A real websiteBundle build (like the aaaaa2780009 one) runs through
//     the normal CatJSRuntime Spider path.
//
// TVBox JSON type 1 / type 4 sources are NOT handled here — see
// JsonSource below (same file, v1, URLSession + JSONDecoder only).
public final class CatSource: SourceRunner {
    public let source: Source
    private let runtime: CatJSRuntime
    private var bundleText: String?
    private var expectedMD5: String?

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
        let apiURL = source.api
        let bundleURL: URL
        if apiURL.pathExtension == "md5" {
            bundleURL = apiURL.deletingPathExtension()
            let (md5Text, _) = try await SubscriptionImporter.fetch(url: apiURL)
            expectedMD5 = md5Text.trimmingCharacters(in: .whitespacesAndNewlines)
            let (jsText, _) = try await SubscriptionImporter.fetch(url: bundleURL)
            guard let expected = expectedMD5, !expected.isEmpty else {
                throw SourceError.parse(".md5 文件为空，无法校验 index.js")
            }
            guard CatJSRuntime.md5Hex(of: jsText) == expected.lowercased() else {
                throw SourceError.parse("index.js 的 MD5 与 .md5 文件不符，拒绝加载")
            }
            bundleText = jsText
        } else {
            bundleURL = apiURL
            let (jsText, _) = try await SubscriptionImporter.fetch(url: bundleURL)
            bundleText = jsText
        }
        guard let jsText = bundleText else { throw SourceError.parse("猫源 bundle 为空") }
        try runtime.load(bundleText: jsText, sourceName: source.name)
    }

    /// What kind of bundle did we actually get? (Used by the UI + fallback.)
    public var bundleKind: CatJSRuntime.BundleKind {
        runtime.bundleKind
    }

    // MARK: SourceRunner — delegated to the JS runtime
    public func home(filter: [String: String]) async throws -> [VideoItem] {
        try await ensureLoaded()
        return try await runtime.home(source: source, filter: filter)
    }

    public func category(typeID: String, page: Int) async throws -> (items: [VideoItem], pageCount: Int) {
        try await ensureLoaded()
        return try await runtime.category(source: source, typeID: typeID, page: page)
    }

    public func detail(vodID: String) async throws -> VideoItem {
        try await ensureLoaded()
        return try await runtime.detail(source: source, vodID: vodID)
    }

    public func search(keyword: String, page: Int) async throws -> [VideoItem] {
        try await ensureLoaded()
        return try await runtime.search(source: source, keyword: keyword, page: page)
    }

    public func playLines(for episode: Episode) async throws -> [PlayLine] {
        try await ensureLoaded()
        return try await runtime.playLines(source: source, episode: episode)
    }

    private func ensureLoaded() async throws {
        if bundleText == nil { try await loadBundle() }
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
