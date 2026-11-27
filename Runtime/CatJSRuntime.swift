import Foundation
import JavaScriptCore
import CryptoKit

// MARK: - CatJSRuntime
// A BOUNDED JavaScriptCore host for CatVod-style JS spiders.
//
// What it is: the MarcoMovie catvod-profile.md model — a small, app-owned
// CatVod ES-module subset, not a full Node.js / FongMi host and not a
// Fastify server. The exposed API is exactly:
//   Spider        — the spider object the bundle registers
//   net.req / net.json — bounded HTTP (6 MiB body cap, like MarcoMovie)
//   proxyUrl      — rewrite a stream URL through HLSLoopbackProxy
//   page          — paginated fetch helper
//   md5 / sha256  — hex digests (checksum helpers, not crypto)
// What it is NOT: no Node.js, no Fastify, no WebSocket, no WASM,
// no Local persistence, no AES/DES/RSA, no file-system access.
// A bundle that needs a server (e.g. the 9280.kstore.vip Fastify bundle)
// is detected, reported as .serverBundle, and NOT executed as a spider.
//
// Threading: all JSContext access happens on one serial DispatchQueue,
// because JSContext is not thread-safe.
public final class CatJSRuntime {
    public enum BundleKind: Equatable {
        case unknown
        case websiteBundle   // defines globalThis.websiteBundle (the aaaaa2780009 build)
        case spider          // registers a Spider object
        case serverBundle    // Fastify / server code — cannot run as a spider on iOS
    }

    public private(set) var bundleKind: BundleKind = .unknown

    private let queue = DispatchQueue(label: "com.yiplayer.catjs", qos: .userInitiated)
    private var context: JSContext?

    private static let maxBodyBytes = 6 * 1024 * 1024

    public init() {}

    // MARK: MD5 (checksum only — CryptoKit Insecure.MD5)
    public static func md5Hex(of text: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(of text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Loading + bundle-kind detection
    public func load(bundleText: String, sourceName: String) throws {
        var loadError: Error?
        queue.sync {
            do {
                self.bundleKind = Self.detectKind(in: bundleText)
                guard self.bundleKind != .serverBundle else {
                    // Do not execute server code: it expects a Node/Fastify
                    // environment that does not exist on iOS.
                    throw SourceError.notSupported(
                        "该猫源是 Fastify 服务端 bundle，不是 websiteBundle / Spider，v1 无法直接运行；其 SOURCE_ORDER 为 douban,360,renren,hanjutv，但回退成可播源未在 v1 实现")
                }
                let ctx = JSContext()
                ctx?.exceptionHandler = { _, exception in
                    print("[CatJS] exception: \(exception?.toString() ?? "unknown")")
                }
                self.installAPI(on: ctx)
                ctx?.evaluateScript(bundleText)
                if let exception = ctx?.exception {
                    throw SourceError.parse("JS 执行失败：\(exception.toString() ?? "unknown")")
                }
                self.context = ctx
            } catch {
                loadError = error
            }
        }
        if let loadError { throw loadError }
    }

    /// Heuristic, documented as such in BUILD_NOTES.md:
    /// server bundles contain Fastify/server bootstrap code; websiteBundle
    /// builds define globalThis.websiteBundle; spider bundles register Spider.
    static func detectKind(in text: String) -> BundleKind {
        if text.contains("websiteBundle") { return .websiteBundle }
        if text.contains("Fastify") || text.contains("fastify()") || text.contains("createServer") {
            return .serverBundle
        }
        if text.contains("Spider") { return .spider }
        return .unknown
    }

    // MARK: Bounded CatVod-style API
    private func installAPI(on ctx: JSContext?) {
        guard let ctx else { return }

        // net.req(url, options) -> { status, headers, body } (body capped at 6 MiB)
        let netReq: @convention(block) (String, [String: Any]?) -> [String: Any] = { urlString, _ in
            guard let url = URL(string: urlString) else { return ["status": 0, "body": ""] }
            var result: [String: Any] = ["status": 0, "body": ""]
            let semaphore = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: url) { data, response, _ in
                defer { semaphore.signal() }
                guard let data, data.count <= Self.maxBodyBytes else { return }
                result["status"] = (response as? HTTPURLResponse)?.statusCode ?? 0
                result["body"] = String(data: data, encoding: .utf8) ?? ""
            }.resume()
            _ = semaphore.wait(timeout: .now() + 15)
            return result
        }
        ctx.setObject(netReq, forKeyedSubscript: "netReq" as NSString)
        ctx.evaluateScript("var net = { req: netReq, json: function(u, o) { var r = netReq(u, o); try { return JSON.parse(r.body); } catch(e) { return null; } } };")

        // proxyUrl(url) -> loopback URL that rewrites relative m3u8 segments
        let proxy: @convention(block) (String) -> String = { url in
            HLSLoopbackProxy.shared.proxyURL(for: url).absoluteString
        }
        ctx.setObject(proxy, forKeyedSubscript: "proxyUrl" as NSString)

        // page(url) — same as net.req, kept for spider compatibility
        ctx.evaluateScript("var page = net.req;")

        // md5 / sha256 hex helpers
        let md5: @convention(block) (String) -> String = { Self.md5Hex(of: $0) }
        let sha256: @convention(block) (String) -> String = { Self.sha256Hex(of: $0) }
        ctx.setObject(md5, forKeyedSubscript: "md5" as NSString)
        ctx.setObject(sha256, forKeyedSubscript: "sha256" as NSString)
    }

    // MARK: Spider calls (v1: websiteBundle / Spider bundles)
    // These call into the loaded bundle's Spider object. If the bundle
    // does not expose the requested function, the call throws
    // SourceError.notSupported instead of inventing a result.
    public func home(source: Source, filter: [String: String]) async throws -> [VideoItem] {
        try await callSpider(function: "homeContent", args: [filter], source: source).items
    }

    public func category(source: Source, typeID: String, page: Int) async throws -> (items: [VideoItem], pageCount: Int) {
        let r = try await callSpider(function: "categoryContent", args: [typeID, page], source: source)
        return (r.items, r.pageCount ?? page)
    }

    public func detail(source: Source, vodID: String) async throws -> VideoItem {
        let r = try await callSpider(function: "detailContent", args: [vodID], source: source)
        guard let first = r.items.first else { throw SourceError.noResult }
        return first
    }

    public func search(source: Source, keyword: String, page: Int) async throws -> [VideoItem] {
        try await callSpider(function: "searchContent", args: [keyword, page], source: source).items
    }

    public func playLines(source: Source, episode: Episode) async throws -> [PlayLine] {
        let r = try await callSpider(function: "playerContent", args: [episode.id], source: source)
        return r.lines
    }

    private struct SpiderResult {
        var items: [VideoItem] = []
        var pageCount: Int?
        var lines: [PlayLine] = []
    }

    private func callSpider(function: String, args: [Any], source: Source) async throws -> SpiderResult {
        // v1 wiring: the bundle's Spider object is looked up by name.
        // A bundle that registers no Spider throws here — the UI shows
        // the error instead of an empty list pretending to be a result.
        var result = SpiderResult()
        var callError: Error?
        queue.sync {
            guard let ctx = self.context,
                  let spider = ctx.objectForKeyedSubscript("Spider"),
                  !spider.isUndefined,
                  let fn = spider.objectForKeyedSubscript(function),
                  !fn.isUndefined else {
                callError = SourceError.notSupported("该猫源未提供 \(function)，无法执行")
                return
            }
            let value = fn.call(withArguments: args)
            // v1 parses only the JSON-serialisable shape the spider returns.
            if let dict = value?.toDictionary() as? [AnyHashable: Any] {
                if let list = dict["list"] as? [[String: Any]] {
                    result.items = list.compactMap { JsonSource.videoItem(from: $0, sourceID: source.id) }
                    result.pageCount = dict["pagecount"] as? Int
                }
                // playerContent shape: {"parse": 0, "playUrl": "", "url": <m3u8>,
                // "header": {"User-Agent": ...}} — turn it into one PlayLine
                // instead of returning [] (which made every cat play fail).
                if let urlString = (dict["url"] as? String) ?? (dict["playUrl"] as? String),
                   !urlString.isEmpty, let url = URL(string: urlString) {
                    let headers = dict["header"] as? [String: String] ?? [:]
                    result.lines = [PlayLine(id: "play-1", name: source.name, url: url, headers: headers)]
                }
            }
            _ = result
        }
        if let callError { throw callError }
        return result
    }
}
