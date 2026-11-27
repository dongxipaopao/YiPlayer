import Foundation

// MARK: - NodeHost
// Swift side of the embedded Node.js runtime (jo32/nodejs-mobile,
// Node.js 26 LTS, V8 without JIT), driving Runtime/NodeHost/host.mjs.
//
// Protocol (see host.mjs, verified against tvbox-silicon's
// Runtime/NodeHost/main.mjs):
//   * Node starts ONCE per process: YiNodeStart(host.mjs, controlFile,
//     relistenFile). host.mjs writes {"port": <n>, "token": "..."} to
//     the control file once its control server listens.
//   * Every call is POST /call with header `x-yingxia-token: <token>`
//     and body {bundle, api, profile, params}; the answer is
//     {"result": "<text>"} or {"error": "<msg>", "errorCode": ...}.
//   * `bundle` is the bundle's file path on disk (the .md5-verified
//     index.js), `api` is the bundle's origin URL (used to fetch its
//     .config.js), `profile` is a per-bundle directory for its settings.
//   * params.catPawOpen = "/spider/<site key>"; params then carries
//     the CatVod call (home/category/detail/search/play — see
//     CatSource.swift).
//
// Lifecycle: Node is started lazily on the first cat call, not at app
// launch — starting it costs seconds and memory, and a user who only
// watches py/JSON sources should never pay it. If Node is already
// running (YiNodeIsRunning), ensureStarted only (re)reads the control
// file.
//
// Suspend/resume: iOS takes back listening sockets while suspended.
// When a /call is refused, Swift appends a line to the relisten file
// (host.mjs watches it and re-listens everything on new ports) and
// retries once after re-reading the control file.
public final class NodeHost {
    public static let shared = NodeHost()

    public static let unavailableMessage =
        "Node.js 运行时未包含在此构建中，猫源服务端 bundle 无法运行"

    private struct ControlInfo: Decodable {
        var port: Int
        var token: String
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()

    private var control: ControlInfo?
    private var startTask: Task<Void, Error>?
    private let lock = NSLock()

    private init() {}

    // MARK: Locations
    private static var nodeHostDirURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("nodehost")
    }

    private static var supportDirURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YiPlayer/node", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var controlFileURL: URL { Self.supportDirURL.appendingPathComponent("control.json") }
    private var relistenFileURL: URL { Self.supportDirURL.appendingPathComponent("relisten") }

    public var isAvailable: Bool {
        guard let dir = Self.nodeHostDirURL else { return false }
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("host.mjs").path)
            && FileManager.default.fileExists(atPath: dir.appendingPathComponent("worker.mjs").path)
    }

    // MARK: Start (once)
    public func ensureStarted() async throws {
        if control != nil { return }
        if let task = startTask {
            try await task.value
            return
        }
        let task = Task<Void, Error> {
            try await self.start()
        }
        lock.lock(); startTask = task; lock.unlock()
        defer { lock.lock(); startTask = nil; lock.unlock() }
        try await task.value
    }

    private func start() async throws {
        guard isAvailable, let dir = Self.nodeHostDirURL else {
            throw SourceError.notSupported(Self.unavailableMessage)
        }
        let main = dir.appendingPathComponent("host.mjs")
        // Touch the relisten file so host.mjs can watch it.
        if !FileManager.default.fileExists(atPath: relistenFileURL.path) {
            FileManager.default.createFile(atPath: relistenFileURL.path, contents: Data())
        }
        // Remove a stale control file: a port from a previous launch is dead.
        try? FileManager.default.removeItem(at: controlFileURL)
        let rc = YiNodeStart(main.path, controlFileURL.path, relistenFileURL.path)
        guard rc == 0 || YiNodeIsRunning() != 0 else {
            throw SourceError.parse("Node.js 启动失败（错误码 \(rc)）")
        }
        // Wait for host.mjs to announce its control port (up to 30 s).
        let deadline = Date.now.addingTimeInterval(30)
        while Date.now < deadline {
            if let data = try? Data(contentsOf: controlFileURL),
               let info = try? JSONDecoder().decode(ControlInfo.self, from: data) {
                control = info
                return
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw SourceError.parse("Node.js 启动超时（30 秒内未就绪）")
    }

    private func refreshControl() {
        if let data = try? Data(contentsOf: controlFileURL),
           let info = try? JSONDecoder().decode(ControlInfo.self, from: data) {
            control = info
        }
    }

    /// Ask the host to re-listen (after a suspend) and re-read the port.
    private func relisten() async {
        if let handle = try? FileHandle(forWritingTo: relistenFileURL) {
            handle.seekToEndOfFile()
            handle.write(Data("\n".utf8))
            try? handle.close()
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        refreshControl()
    }

    // MARK: Calls
    /// One /call round-trip. `bundle` is the bundle file path,
    /// `api` its origin URL, `profile` its settings directory.
    public func call(bundle: String, api: String, profile: String,
                     params: [String: Any]) async throws -> String {
        try await ensureStarted()
        guard let control else { throw SourceError.parse("Node.js 控制端口未知") }
        let body: [String: Any] = ["bundle": bundle, "api": api, "profile": profile,
                                   "params": params]
        let data = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(control.port)/call")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(control.token, forHTTPHeaderField: "x-yingxia-token")
        request.httpBody = data
        do {
            return try await perform(request: request)
        } catch let error as URLError where error.code == .cannotConnectToHost {
            // Suspend took the socket back: ask host.mjs to re-listen,
            // then try once more on the (possibly new) port.
            await relisten()
            guard let fresh = self.control else { throw error }
            request.url = URL(string: "http://127.0.0.1:\(fresh.port)/call")
            request.setValue(fresh.token, forHTTPHeaderField: "x-yingxia-token")
            return try await perform(request: request)
        }
    }

    private func perform(request: URLRequest) async throws -> String {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SourceError.network("Node 控制服务 HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SourceError.parse("Node 控制服务返回了无法解析的结果")
        }
        if let error = json["error"] as? String {
            throw SourceError.parse(error)
        }
        guard let result = json["result"] as? String else {
            throw SourceError.parse("Node 控制服务没有返回 result")
        }
        return result
    }

    /// GET /config on the bundle's server: the site list a server
    /// bundle offers (best-effort parse — see CatSource.sites).
    /// host.mjs answers catConfig before it looks at catPawOpen, so
    /// no spider route is needed here.
    public func config(bundle: String, api: String, profile: String) async throws -> String {
        try await call(bundle: bundle, api: api, profile: profile,
                       params: ["catConfig": true])
    }
}
