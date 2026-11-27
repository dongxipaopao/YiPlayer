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
// v2 STATUS: REAL. Embedded CPython 3.13 (BeeWare Python-Apple-support,
// downloaded by Scripts/fetch-python.sh in CI, NOT committed) behind
// the C bridge Runtime/PythonHost/ApplePython.c. The bridge exposes one
// function — call one spider method, get JSON back — and all spider
// logic lives in Python (Runtime/PythonHost/spiders/_yi_bridge.py).
// pd.py runs with a minimal `base.spider` shim
// (Runtime/PythonHost/spiders/base/spider.py: only the methods pd.py
// actually uses) and a pure-Python `requests` stack
// (Runtime/PythonHost/requirements.txt, installed by CI into
// spiders/site-packages; no compiled wheels, no lxml/bs4 — pd.py
// parses JSON only and never imports them).
//
// The v1 "iOS 暂不支持" fallback is kept ONLY for the case the Python
// framework is absent at runtime (e.g. a build made before the fetch
// step ran): EmbeddedPythonHost throws the same message then, and
// nothing else pretends to play.
public protocol PySourceHost: AnyObject {
    /// Load a spider file (pd.py or any CatVod py spider) for this source.
    func loadSpider(source: Source, script: String) throws
    func home(source: Source, filter: [String: String]) async throws -> [VideoItem]
    func categories(source: Source) async throws -> [(id: String, name: String)]
    func category(source: Source, typeID: String, page: Int, filter: [String: String]) async throws -> (items: [VideoItem], pageCount: Int)
    func detail(source: Source, vodID: String) async throws -> VideoItem
    func search(source: Source, keyword: String, page: Int) async throws -> [VideoItem]
    func playLines(source: Source, episode: Episode) async throws -> [PlayLine]
}

// MARK: - EmbeddedPythonHost (v2, real)
/// Runs a CatVod py spider in the embedded CPython interpreter.
///
/// Threading: CPython has one interpreter and one GIL. Every bridge
/// call goes through one serial queue, so two spiders can never run
/// at once (Yingxia's SerializedPluginWorker does the same). The
/// blocking network calls pd.py makes (requests, 15 s timeout) happen
/// on that background queue, never on the main thread.
///
/// Initialisation (v2.1.1 — read before changing): the interpreter
/// is initialised ONCE, on this serial queue, and the outcome is
/// cached (see ensureInitialized). CPython 3.13's
/// Py_InitializeFromConfig may only be attempted once per process:
/// its core init sets runtime->core_initialized = 1 as soon as the
/// interpreter object exists, and if the later main init then fails,
/// a second call from any other thread takes the reconfigure branch
/// (Python/pylifecycle.c: pyinit_core_reconfigure) and fails with
/// "failed to read thread state" because the thread state belongs to
/// the first thread. v2.1.0 called ensureInitialized() from
/// arbitrary Swift executor threads on every Discover/Search/Home
/// call, with no lock — so after the first failure every later call
/// failed with exactly that misleading message. The reference
/// implementation (tvbox-silicon EmbeddedPythonHost +
/// ApplePython.c: dispatch_once_f + a cached `failure` string that
/// every later request answers with; MarcoMovie's native-python
/// profile: "its current failure policy retires a failed source")
/// does the same: one attempt, cached outcome, no retries.
///
/// First call cost: the interpreter initialises once per process.
/// Expect a slow first py call (Yingxia measured ~18 s cold start in
/// the simulator for the full plan; YiPlayer's bundle is smaller —
/// stdlib + requests only — but the first call still loads the whole
/// interpreter). The UI shows its normal loading state meanwhile.
public final class EmbeddedPythonHost: PySourceHost {
    public static let unavailableMessage =
        "iOS 暂不支持 Python 运行时（Python 框架未包含在此构建中）"

    private let queue = DispatchQueue(label: "com.yiplayer.python", qos: .userInitiated)
    private var initialized = false
    /// v2.1.1: the first initialisation failure, cached forever.
    /// A failed interpreter stays failed for the life of the process
    /// (CPython cannot be re-initialised after a half-finished init),
    /// so later calls throw this instead of retrying — retrying from
    /// another thread only produces "failed to read thread state".
    /// Only ever read/written on `queue` (see call()).
    private var initFailure: SourceError?
    /// Last detail payload per source id, so playLines(for:) can resolve
    /// every line for an episode number from its playGroups.
    private var lastDetail: [String: VideoItem] = [:]
    /// Resolved spider file path per source id.
    private var scriptPaths: [String: String] = [:]

    public init() {}

    // MARK: Paths
    private static var pythonFrameworkURL: URL? {
        Bundle.main.url(forResource: "Python", withExtension: "framework",
                        subdirectory: "Frameworks")
    }

    /// v2.1: the CPython stdlib, staged into the bundle by
    /// Scripts/fetch-python.sh (project.yml folder reference).
    /// v2.0.0 looked for it under <Python.framework>/lib/python3.13,
    /// which does not exist anywhere in the BeeWare package — that is
    /// why every first py call failed with error code 4.
    private static var pythonStdlibDirURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("python-stdlib/python3.13")
    }

    private static var spidersDirURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("spiders")
    }

    private static var documentsSpidersDirURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("spiders")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Initialisation (lazy, once, on the serial queue)
    /// MUST only be called on `queue` (call() guarantees this).
    /// Exactly one YiPythonInitialize attempt per process; the
    /// outcome is cached here and in the C bridge, so a failed init
    /// is reported with its true first reason instead of being
    /// retried into "failed to read thread state".
    private func ensureInitialized() throws {
        if initialized { return }
        if let failure = initFailure { throw failure }
        do {
            try ensureInitializedAttempt()
        } catch let error as SourceError {
            initFailure = error
            throw error
        } catch {
            let wrapped = SourceError.parse("Python 运行时初始化失败：\(error.localizedDescription)")
            initFailure = wrapped
            throw wrapped
        }
        initialized = true
    }

    private func ensureInitializedAttempt() throws {
        guard let framework = Self.pythonFrameworkURL,
              let spiders = Self.spidersDirURL,
              let stdlib = Self.pythonStdlibDirURL else {
            // The framework is absent from this build: keep the honest
            // v1 message instead of crashing or pretending.
            throw SourceError.notSupported(Self.unavailableMessage)
        }
        // The stdlib is a bundle resource: prove it is really there
        // before starting the interpreter, and name the exact path
        // when it is not (v2.0.0 only ever said "错误码 4").
        let osPy = stdlib.appendingPathComponent("os.py")
        guard FileManager.default.fileExists(atPath: osPy.path) else {
            throw SourceError.notSupported(
                "Python 标准库未包含在此构建中（未找到 \(osPy.path)），请重新构建")
        }
        let sitePackages = spiders.appendingPathComponent("site-packages")
        let dynload = stdlib.appendingPathComponent("lib-dynload")
        let rc = YiPythonInitialize(
            framework.path,
            stdlib.path,
            dynload.path,
            spiders.path,
            sitePackages.path,
            Self.documentsSpidersDirURL.path)
        guard rc == 0, YiPythonIsReady() != 0 else {
            // v2.1: the C bridge records WHY init failed (PyStatus
            // message + paths tried) — surface it, not just the code.
            // v2.1.1: this is the FIRST failure, cached by the caller;
            // if the interpreter had already failed once, the C
            // bridge returns the cached code without re-entering
            // CPython, so this message stays the true reason.
            let detail = YiPythonLastError().map(String.init(cString:))
                .flatMap { $0.isEmpty ? nil : $0 } ?? "未知原因"
            throw SourceError.parse("Python 运行时初始化失败（错误码 \(rc)）：\(detail)")
        }
    }

    // MARK: One bridge call (serial queue, GIL held inside the C call)
    private func call(scriptPath: String, method: String, args: [Any]) async throws -> Any {
        let argsData = try JSONSerialization.data(withJSONObject: args)
        guard let argsJson = String(data: argsData, encoding: .utf8) else {
            throw SourceError.parse("调用参数编码失败")
        }
        // v2.1.1: initialisation runs INSIDE this queue block, not
        // before it. v2.1.0 called ensureInitialized() here on the
        // Swift executor thread, so concurrent Discover/Search/Home
        // calls raced into Py_InitializeFromConfig from different
        // threads — CPython init is not safe to run twice concurrently
        // (Python/pylifecycle.c: "you cannot use multiple threads"),
        // and the loser failed with "failed to read thread state".
        // Now init and every spider call are serialised on the one
        // queue, exactly like Yingxia's SerializedPluginWorker.
        let raw: String? = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.ensureInitialized()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                guard let cString = YiPythonCallSpider(scriptPath, method, argsJson) else {
                    continuation.resume(returning: nil as String?)
                    return
                }
                defer { YiPythonFreeString(cString) }
                continuation.resume(returning: String(cString: cString))
            }
        }
        guard let raw,
              let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SourceError.parse("Python 桥返回了无法解析的结果")
        }
        guard (json["ok"] as? Bool) == true else {
            throw SourceError.parse((json["error"] as? String) ?? "Python 调用失败")
        }
        return json["result"] ?? NSNull()
    }

    private func dict(_ value: Any) -> [String: Any] {
        value as? [String: Any] ?? [:]
    }

    private func items(from result: Any, sourceID: String) -> [VideoItem] {
        guard let list = dict(result)["list"] as? [[String: Any]] else { return [] }
        return list.compactMap { JsonSource.videoItem(from: $0, sourceID: sourceID) }
    }

    // MARK: Spider file resolution
    private func scriptPath(for source: Source) async throws -> String {
        if let cached = scriptPaths[source.id] { return cached }
        let path: String
        if source.api.isFileURL {
            path = source.api.path
        } else {
            // A remote .py URL: download once into Documents/spiders.
            // (pd.py itself ships in the bundle; this is for spiders the
            // user imports by URL.)
            let (data, _) = try await URLSession.shared.data(from: source.api)
            let file = Self.documentsSpidersDirURL
                .appendingPathComponent("\(source.id).py")
            try data.write(to: file, options: .atomic)
            path = file.path
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw SourceError.parse("蜘蛛文件不存在：\(source.api.lastPathComponent)")
        }
        scriptPaths[source.id] = path
        return path
    }

    // MARK: PySourceHost
    public func loadSpider(source: Source, script: String) throws {
        // Write an inline script into Documents/spiders so the bridge can
        // load it by path on the next call. Empty script = use source.api.
        guard !script.isEmpty else { return }
        let file = Self.documentsSpidersDirURL.appendingPathComponent("\(source.id).py")
        try script.write(to: file, atomically: true, encoding: .utf8)
        scriptPaths[source.id] = file.path
    }

    public func home(source: Source, filter: [String: String]) async throws -> [VideoItem] {
        // pd.py's homeContent returns classes/filters only, no videos.
        // The home shelf is homeVideoContent (feed snapshot).
        let path = try await scriptPath(for: source)
        let result = try await call(scriptPath: path, method: "homeVideoContent", args: [])
        return items(from: result, sourceID: source.id)
    }

    public func categories(source: Source) async throws -> [(id: String, name: String)] {
        let path = try await scriptPath(for: source)
        let result = try await call(scriptPath: path, method: "homeContent", args: [[String: Any]()])
        guard let classes = dict(result)["class"] as? [[String: Any]] else {
            // A spider without homeContent classes: fall back to pd.py's
            // documented KINDS (all/movie/series/short_drama/anime/variety).
            return [("all", "全部"), ("movie", "电影"), ("series", "剧集"),
                    ("short_drama", "短剧"), ("anime", "动漫"), ("variety", "综艺")]
        }
        return classes.compactMap { d in
            guard let id = d["type_id"] as? String,
                  let name = d["type_name"] as? String else { return nil }
            return (id, name)
        }
    }

    public func category(source: Source, typeID: String, page: Int,
                         filter: [String: String]) async throws -> (items: [VideoItem], pageCount: Int) {
        let path = try await scriptPath(for: source)
        // pd.py reads extend["window"] (day/week/month/total); default day.
        let extend: [String: Any] = ["window": filter["window"] ?? "day"]
        let result = try await call(scriptPath: path, method: "categoryContent",
                                    args: [typeID, page, [String: Any](), extend])
        let pageCount = (dict(result)["pagecount"] as? Int) ?? page
        return (items(from: result, sourceID: source.id), pageCount)
    }

    public func detail(source: Source, vodID: String) async throws -> VideoItem {
        let path = try await scriptPath(for: source)
        let result = try await call(scriptPath: path, method: "detailContent", args: [[vodID]])
        guard let item = items(from: result, sourceID: source.id).first else {
            throw SourceError.noResult
        }
        lastDetail[source.id] = item
        return item
    }

    public func search(source: Source, keyword: String, page: Int) async throws -> [VideoItem] {
        // pd.py searchContent(key, quick) has no page parameter: it
        // always fetches page 1. Page > 1 returns the same first page;
        // the UI does not offer "load more" for py search.
        let path = try await scriptPath(for: source)
        let result = try await call(scriptPath: path, method: "searchContent",
                                    args: [keyword, false])
        return items(from: result, sourceID: source.id)
    }

    public func playLines(source: Source, episode: Episode) async throws -> [PlayLine] {
        // Resolve every line for this episode number via playerContent:
        // pd.py's play id is "<token>" or "<token>@@<line_id>".
        let path = try await scriptPath(for: source)
        guard let detail = lastDetail[source.id], detail.id == episode.vodID else {
            // No detail cached (deep link straight to play): resolve the
            // episode's own playURL if it is direct, else fail honestly.
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
            let result = try await call(scriptPath: path, method: "playerContent",
                                        args: [name, playID, ""])
            let d = dict(result)
            guard let urlString = d["url"] as? String, !urlString.isEmpty,
                  let url = URL(string: urlString) else { continue }
            let headers = d["header"] as? [String: String] ?? [:]
            lines.append(PlayLine(id: "\(episode.vodID)-\(lineIndex)-\(episode.number)",
                                  name: name, url: url, headers: headers))
        }
        guard !lines.isEmpty else { throw SourceError.noResult }
        return lines
    }
}

// MARK: - PySource runner (wires the real host to SourceRunner)
public final class PySource: SourceRunner {
    public let source: Source
    private let host: PySourceHost
    /// The spider script text (e.g. pd.py), kept so an inline script can
    /// be written to Documents/spiders and loaded by path.
    public var spiderScript: String?

    public init(source: Source, host: PySourceHost = EmbeddedPythonHost()) {
        self.source = source
        self.host = host
    }

    public func home(filter: [String: String]) async throws -> [VideoItem] {
        try await host.home(source: source, filter: filter)
    }

    public func categories() async throws -> [(id: String, name: String)] {
        try await host.categories(source: source)
    }

    public func category(typeID: String, page: Int) async throws -> (items: [VideoItem], pageCount: Int) {
        try await category(typeID: typeID, page: page, filter: [:])
    }

    public func category(typeID: String, page: Int, filter: [String: String]) async throws -> (items: [VideoItem], pageCount: Int) {
        try await host.category(source: source, typeID: typeID, page: page, filter: filter)
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
