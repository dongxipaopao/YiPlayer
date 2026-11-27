import Foundation
import Network

// MARK: - HLSLoopbackProxy
// A tiny local HTTP server on 127.0.0.1 that rewrites relative .m3u8
// segments / keys to absolute URLs — the same job as Yingxia's
// RemuxServer and MarcoMovie's LocalHeaderProxyServer (NWListener).
//
// Why it exists: cat/py sources hand out m3u8 playlists whose segment
// lines are relative ("2000k/hls/index.m3u8", "0000000.ts", key URIs).
// AVPlayer resolves them against the playlist URL, which is often wrong
// (signed CDN paths, proxy prefixes). Routing the playlist through the
// loopback proxy lets YiPlayer rewrite every relative line to an
// absolute URL (and re-wrap nested playlists) before AVPlayer sees it.
//
// v1 scope: plain HTTP/1.1, GET only, one request at a time per
// connection, no TLS, no auth — it only ever binds 127.0.0.1 and only
// serves URLs the app itself asked it to proxy. It does NOT transcode
// or decrypt anything; segment bytes pass through untouched.
// Port: the OS picks an ephemeral port at start; proxyURL(for:) embeds it.
public final class HLSLoopbackProxy {
    public static let shared = HLSLoopbackProxy()

    private var listener: NWListener?
    private var port: UInt16 = 0
    private let queue = DispatchQueue(label: "com.yiplayer.hlsproxy", qos: .userInitiated)
    private var isRunning = false

    private init() {}

    public func start() throws {
        guard !isRunning else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.hostPort(host: .loopback, port: .any))
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                // The port is only assigned once the listener is ready;
                // reading it right after start() can still return 0.
                self?.port = listener.port?.rawValue ?? 0
            case .failed(let error):
                print("[HLSLoopbackProxy] listener failed: \(error)")
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        isRunning = true
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    /// The loopback URL AVPlayer should load for `original` (an m3u8 URL).
    public func proxyURL(for original: String) -> URL {
        let encoded = original.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "http://127.0.0.1:\(port)/proxy?url=\(encoded)")!
    }

    // MARK: Minimal HTTP/1.1 handling
    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self, let data, error == nil,
                  let request = String(data: data, encoding: .utf8),
                  let target = Self.targetURL(from: request) else {
                connection.cancel()
                return
            }
            Task { await self.serve(target: target, on: connection) }
        }
    }

    private static func targetURL(from request: String) -> URL? {
        // First line: "GET /proxy?url=<encoded> HTTP/1.1"
        guard let firstLine = request.components(separatedBy: "\r\n").first,
              firstLine.hasPrefix("GET ") else { return nil }
        let path = firstLine.dropFirst(4).split(separator: " ").first.map(String.init) ?? ""
        guard let components = URLComponents(string: "http://127.0.0.1\(path)"),
              let encoded = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let url = URL(string: encoded) else { return nil }
        return url
    }

    private func serve(target: URL, on connection: NWConnection) async {
        do {
            let (data, response) = try await URLSession.shared.data(from: target)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                send(connection: connection, status: 502, contentType: "text/plain", body: Data())
                return
            }
            let isPlaylist = target.pathExtension.lowercased() == "m3u8"
                || (http.mimeType?.contains("mpegurl") ?? false)
            if isPlaylist, let text = String(data: data, encoding: .utf8), text.hasPrefix("#EXTM3U") {
                let rewritten = rewritePlaylist(text, base: target)
                send(connection: connection, status: 200,
                     contentType: "application/vnd.apple.mpegurl",
                     body: Data(rewritten.utf8))
            } else {
                send(connection: connection, status: 200,
                     contentType: http.mimeType ?? "application/octet-stream", body: data)
            }
        } catch {
            send(connection: connection, status: 502, contentType: "text/plain", body: Data())
        }
    }

    /// Rewrite relative segment / key / nested-playlist lines to absolute
    /// URLs, re-wrapped through this proxy (same rule as 555.py localProxy
    /// do=m3u8: relative -> absolute -> re-wrapped, #EXT-X-KEY URIs too).
    func rewritePlaylist(_ text: String, base: URL) -> String {
        var out: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") {
                if line.hasPrefix("#EXT-X-KEY"), line.contains("URI=\"") {
                    let parts = line.components(separatedBy: "URI=\"")
                    guard parts.count == 2 else { out.append(line); continue }
                    let keyPart = parts[1].components(separatedBy: "\"").first ?? ""
                    let absolute = URL(string: keyPart, relativeTo: base)?.absoluteURL
                    let proxied = absolute.map { proxyURL(for: $0.absoluteString).absoluteString } ?? keyPart
                    out.append(line.replacingOccurrences(of: keyPart, with: proxied))
                } else {
                    out.append(line)
                }
                continue
            }
            let absolute = URL(string: line, relativeTo: base)?.absoluteURL
            if let absolute {
                let isNested = absolute.pathExtension.lowercased() == "m3u8"
                _ = isNested // nested playlists are re-wrapped the same way
                out.append(proxyURL(for: absolute.absoluteString).absoluteString)
            } else {
                out.append(line)
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    private func send(connection: NWConnection, status: Int, contentType: String, body: Data) {
        var header = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Bad Gateway")\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
