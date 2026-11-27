import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - SettingsView + SubscriptionView
// Subscription import, multi-subscription list, failure keeps the last
// good config (see SubscriptionStore), and the honest v2 capability list.
//
// Import routes (v2 — the user runs YiPlayer inside LiveContainer, so
// no route may depend on the file picker alone):
//   1. URL paste (TVBox JSON / cat .js / .js.md5 / .py spider URL)
//   2. Paste subscription TEXT (multi-line box + paste-from-clipboard):
//      TVBox JSON text, a .py spider, or a .js bundle pasted in.
//      This is the fallback when the file picker cannot reach a file.
//   3. Local file (.json / .js / .py / .txt): the picked file is
//      COPIED into the app's own Documents/imports/ first (under
//      security-scoped access), then read from the copy — reading the
//      security-scoped URL directly is unreliable under LiveContainer's
//      sandbox, and a copied file keeps working after the picker closes.
//   4. Every failure shows a concrete reason on screen, never a bare
//      "cancelled": a cancelled picker says so plainly, anything else
//      names the step that failed and points at the paste route.
struct SettingsView: View {
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @EnvironmentObject private var history: HistoryStore
    @State private var urlText = SubscriptionImporter.defaultCatURL.absoluteString
    @State private var pasteText = ""
    @State private var isImporting = false
    @State private var importMessage: String?
    @State private var showFilePicker = false
    @State private var showClearHistoryConfirm = false
    /// Discovered cat sites per source id (from the bundle's /config).
    @State private var catSites: [String: [(key: String, name: String)]] = [:]
    @State private var loadingSitesFor: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("订阅源") {
                    TextField("订阅地址（TVBox JSON / 猫源 .js / .js.md5 / py .py）", text: $urlText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        Button("导入") { Task { await importFromURL() } }
                            .disabled(isImporting || urlText.isEmpty)
                        Button("本地文件") { showFilePicker = true }
                    }
                    if let importMessage {
                        Text(importMessage).font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(subscriptions.subscriptions) { sub in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(sub.name).font(.headline)
                            Text("\(sub.sources.count) 个源 · \(sub.kind.rawValue)")
                                .font(.caption).foregroundStyle(.secondary)
                            if let error = sub.lastError {
                                Text("上次刷新失败（已保留上次可用配置）：\(error)")
                                    .font(.caption).foregroundStyle(.red)
                            }
                        }
                        .swipeActions {
                            Button("删除", role: .destructive) { subscriptions.remove(id: sub.id) }
                        }
                    }
                }
                Section("粘贴导入（文件选不了时用这个）") {
                    Text("把订阅 JSON、.py 蜘蛛或 .js 猫源全文粘贴进来，不走文件选择器。")
                        .font(.footnote).foregroundStyle(.secondary)
                    TextEditor(text: $pasteText)
                        .frame(minHeight: 120)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    HStack {
                        Button("从剪贴板粘贴") { pasteFromClipboard() }
                        Button("导入粘贴的文本") { Task { await importFromPaste() } }
                            .disabled(isImporting || pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                catSiteSection
                Section("播放") {
                    Text("播放器：AVPlayer（系统）\nHDR / 4K / 杜比视界原样透传，不转码、不调色。")
                        .font(.subheadline)
                    Text("手势：双击快进 10 秒 · 左半屏亮度 · 右半屏音量 · 长按 2 倍速")
                        .font(.subheadline)
                }
                Section("本机数据") {
                    Button("清除观看历史", role: .destructive) { showClearHistoryConfirm = true }
                        .confirmationDialog("清除全部观看历史？", isPresented: $showClearHistoryConfirm) {
                            Button("清除", role: .destructive) { history.clear() }
                        }
                }
                Section("关于 v2") {
                    Text("YiPlayer 2.0.0\n• 支持：TVBox JSON type 1/4、py 源（内嵌 CPython）、猫源（JavaScriptCore 有界宿主 + 内嵌 Node.js 服务端 bundle）\n• 首次打开已预置懂片帝和 9280 猫源，不用先导入\n• 不含内置片库、云盘、音乐、漫画、小说")
                        .font(.subheadline)
                    Text("py 源：内嵌 CPython 3.13 运行 pd.py（懂片帝）。首次调用会慢一些（解释器冷启动），之后正常。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("猫源：9280 那个 Fastify 服务端 bundle 走内嵌 Node.js 26 运行；真正的 websiteBundle 仍走 JavaScriptCore。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .fileImporter(isPresented: $showFilePicker,
                          allowedContentTypes: [.json, .javascript, .pythonScript, .plainText, .data],
                          allowsMultipleSelection: false) { result in
                importFromFile(result: result)
            }
        }
    }

    // MARK: - Cat site picker (server-bundle sources only)
    @ViewBuilder
    private var catSiteSection: some View {
        let catSources = subscriptions.allSources.filter { $0.kind == .cat }
        if !catSources.isEmpty {
            Section("猫源站点") {
                Text("服务端 bundle（比如 9280）里有多个站点，默认用 /config 返回的第一个。这里可以切换。")
                    .font(.footnote).foregroundStyle(.secondary)
                ForEach(catSources) { source in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(source.name).font(.headline)
                        if let sites = catSites[source.id], !sites.isEmpty {
                            Picker("站点", selection: siteKeyBinding(for: source)) {
                                ForEach(sites, id: \.key) { site in
                                    Text(site.name).tag(site.key)
                                }
                            }
                            .pickerStyle(.menu)
                        } else {
                            Text("当前站点：\(currentSiteKey(for: source))（未加载过站点列表）")
                                .font(.caption).foregroundStyle(.secondary)
                            Button(loadingSitesFor == source.id ? "加载中…" : "加载站点列表") {
                                Task { await loadCatSites(for: source) }
                            }
                            .disabled(loadingSitesFor != nil)
                        }
                    }
                }
            }
        }
    }

    private func currentSiteKey(for source: Source) -> String {
        UserDefaults.standard.string(forKey: "yiplayer.cat.site.\(source.id)") ?? "douban"
    }

    private func siteKeyBinding(for source: Source) -> Binding<String> {
        Binding(
            get: { currentSiteKey(for: source) },
            set: { UserDefaults.standard.set($0, forKey: "yiplayer.cat.site.\(source.id)") }
        )
    }

    private func loadCatSites(for source: Source) async {
        loadingSitesFor = source.id
        defer { loadingSitesFor = nil }
        do {
            let runner = CatSource(source: source)
            try await runner.loadBundle()
            catSites[source.id] = runner.sites
            if runner.sites.isEmpty {
                importMessage = "「\(source.name)」没有返回站点列表，将用默认站点 douban。"
            }
        } catch {
            importMessage = "加载「\(source.name)」站点列表失败：\(error.localizedDescription)"
        }
    }

    // MARK: - URL import
    private func importFromURL() async {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            importMessage = "地址无效"
            return
        }
        isImporting = true
        defer { isImporting = false }
        do {
            let (text, finalURL) = try await SubscriptionImporter.fetch(url: url)
            let sub = try parseSubscription(text: text, url: finalURL)
            subscriptions.add(sub)
            importMessage = "已导入「\(sub.name)」：\(sub.sources.count) 个源"
        } catch {
            importMessage = "导入失败：\(error.localizedDescription)（已保留上次可用配置）"
        }
    }

    // MARK: - Paste import (no file picker involved)
    private func pasteFromClipboard() {
        if let text = UIPasteboard.general.string, !text.isEmpty {
            pasteText = text
            importMessage = "已从剪贴板粘贴 \(text.count) 字，点“导入粘贴的文本”。"
        } else {
            importMessage = "剪贴板里没有文本。先去别处复制订阅内容，再回来点这个按钮。"
        }
    }

    private func importFromPaste() async {
        let text = pasteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isImporting = true
        defer { isImporting = false }
        do {
            let sub = try parsePasted(text: text)
            subscriptions.add(sub)
            importMessage = "已导入「\(sub.name)」：\(sub.sources.count) 个源"
            pasteText = ""
        } catch {
            importMessage = "粘贴导入失败：\(error.localizedDescription)"
        }
    }

    /// Route pasted text by content (same sniffing as .txt files).
    private func parsePasted(text: String) throws -> Subscription {
        switch Self.sniffTextKind(text) {
        case .json:
            return try parseSubscription(text: text, url: nil)
        case .py:
            let file = Self.documentsFile(named: "pasted-\(UUID().uuidString.prefix(8)).py",
                                          in: "spiders")
            try text.write(to: file, atomically: true, encoding: .utf8)
            let id = UUID()
            let source = Source(id: "py-pasted-\(id.uuidString.prefix(8))", name: "粘贴的 py 源",
                                kind: .py, api: file, spider: file.lastPathComponent,
                                subscriptionID: id.uuidString)
            return Subscription(id: id, name: "粘贴的 py 源", url: file,
                                kind: .pySpider, sources: [source], lastGoodAt: Date())
        case .js:
            let file = Self.documentsFile(named: "pasted-\(UUID().uuidString.prefix(8)).js",
                                          in: "imports")
            try text.write(to: file, atomically: true, encoding: .utf8)
            let id = UUID()
            let source = Source(id: "cat-pasted-\(file.lastPathComponent)", name: "粘贴的猫源",
                                kind: .cat, api: file, subscriptionID: id.uuidString)
            return Subscription(id: id, name: "粘贴的猫源", url: file, kind: .catBundle, sources: [source])
        case .unknown:
            throw SourceError.parse("无法识别粘贴的内容（只支持 TVBox JSON、.py 蜘蛛、.js 猫源）")
        }
    }

    // MARK: - Local file import (copy into Documents first)
    private func importFromFile(result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            // A cancelled picker is not an error: say so plainly and
            // stop. Anything else names the failure and points at paste.
            if (error as NSError).code == NSUserCancelledError {
                importMessage = "已取消，未导入任何文件。"
            } else {
                importMessage = "文件导入失败：\(error.localizedDescription)。可以改用上方的粘贴导入，把文件内容粘贴进来。"
            }
            return
        case .success(let urls):
            guard let url = urls.first else {
                importMessage = "没有选中文件。"
                return
            }
            importFile(url: url)
        }
    }

    /// Copy the picked file into the app's own Documents/imports/ under
    /// security-scoped access, then read the COPY. Under LiveContainer
    /// the security-scoped URL itself is unreliable to read from
    /// directly (and dies when the picker closes); the copy keeps
    /// working. The copy is also what the runners use as the source
    /// file, so an imported spider/bundle survives app restarts.
    private func importFile(url: URL) {
        let fileName = url.lastPathComponent
        guard url.startAccessingSecurityScopedResource() else {
            importMessage = "无法访问这个文件（容器沙盒限制，LiveContainer 下常见）。请改用上方的粘贴导入，把文件内容粘贴进来。"
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        // .py files go straight to Documents/spiders/ (where the
        // Python host looks for user spiders); everything else to imports/.
        let subdir = url.pathExtension.lowercased() == "py" ? "spiders" : "imports"
        let copy = Self.documentsFile(named: fileName, in: subdir)
        do {
            if FileManager.default.fileExists(atPath: copy.path) {
                try FileManager.default.removeItem(at: copy)
            }
            try FileManager.default.copyItem(at: url, to: copy)
        } catch {
            importMessage = "复制文件失败：\(error.localizedDescription)。请改用上方的粘贴导入。"
            return
        }
        guard let text = try? String(contentsOf: copy, encoding: .utf8) else {
            importMessage = "文件「\(fileName)」不是 UTF-8 文本，无法导入。"
            return
        }
        do {
            let sub = try parseSubscription(text: text, url: copy, fileName: fileName)
            subscriptions.add(sub)
            importMessage = "已导入本地文件「\(fileName)」：\(sub.sources.count) 个源"
        } catch {
            importMessage = "导入失败：\(error.localizedDescription)（已保留上次可用配置）"
        }
    }

    private static func documentsFile(named fileName: String, in subdir: String) -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(subdir, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    /// What kind of subscription is this text? Used for .txt files and paste.
    enum TextKind { case json, js, py, unknown }

    static func sniffTextKind(_ text: String) -> TextKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") { return .json }
        if trimmed.contains("class Spider") || trimmed.contains("def homeContent")
            || trimmed.contains("def homeVideoContent") { return .py }
        if trimmed.contains("websiteBundle") || trimmed.contains("Fastify")
            || trimmed.contains("fastify") || trimmed.contains("catServerFactory")
            || trimmed.contains("Spider") { return .js }
        return .unknown
    }

    /// Parse a subscription document into a Subscription.
    /// TVBox JSON -> sources; a cat .js bundle -> one cat source whose
    /// api is the bundle URL (its .md5 is verified at load time);
    /// a .py spider -> one py source (api = the copied file URL).
    /// url == nil (pasted JSON): relative site APIs cannot be resolved
    /// and are skipped; absolute APIs work as normal.
    private func parseSubscription(text: String, url: URL?, fileName: String? = nil) throws -> Subscription {
        let ext = (fileName ?? url?.lastPathComponent ?? "").lowercased()
        if url?.pathExtension == "md5" || ext.hasSuffix(".js") {
            let name = (fileName ?? url?.deletingPathExtension().lastPathComponent) ?? "猫源"
            let api = url ?? Self.documentsFile(named: name, in: "imports")
            let id = UUID()
            let source = Source(id: "cat-\(name)", name: name, kind: .cat,
                                api: api, subscriptionID: id.uuidString)
            return Subscription(id: id, name: name, url: url, kind: .catBundle, sources: [source])
        }
        if ext.hasSuffix(".py") {
            let name = (fileName ?? url?.lastPathComponent) ?? "py 源"
            let api = url ?? Self.documentsFile(named: name, in: "spiders")
            let id = UUID()
            let source = Source(id: "py-\(name)", name: name, kind: .py,
                                api: api, spider: name, subscriptionID: id.uuidString)
            return Subscription(id: id, name: name, url: url, kind: .pySpider,
                                sources: [source], lastGoodAt: Date())
        }
        if ext.hasSuffix(".txt") {
            // .txt: sniff the content instead of trusting the extension,
            // and write it out under the right extension so the runners
            // can find it (a .txt copy named "spider.py" would not be
            // the file the Python host looks for).
            let base = (fileName ?? "spider").replacingOccurrences(of: ".txt", with: "")
            switch Self.sniffTextKind(text) {
            case .json:
                break // fall through to the JSON branch below
            case .py:
                let pyFile = Self.documentsFile(named: "\(base).py", in: "spiders")
                try text.write(to: pyFile, atomically: true, encoding: .utf8)
                let id = UUID()
                let source = Source(id: "py-\(base)", name: base, kind: .py,
                                    api: pyFile, spider: pyFile.lastPathComponent,
                                    subscriptionID: id.uuidString)
                return Subscription(id: id, name: base, url: pyFile, kind: .pySpider,
                                    sources: [source], lastGoodAt: Date())
            case .js:
                let jsFile = Self.documentsFile(named: "\(base).js", in: "imports")
                try text.write(to: jsFile, atomically: true, encoding: .utf8)
                let id = UUID()
                let source = Source(id: "cat-\(base)", name: base, kind: .cat,
                                    api: jsFile, subscriptionID: id.uuidString)
                return Subscription(id: id, name: base, url: jsFile, kind: .catBundle, sources: [source])
            case .unknown:
                throw SourceError.parse("无法识别这个 .txt 文件的内容（只支持 TVBox JSON、.py 蜘蛛、.js 猫源）")
            }
        }
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sites = json["sites"] as? [[String: Any]] else {
            throw SourceError.parse("无法识别的订阅格式（只支持 TVBox JSON / 猫源 .js / .js.md5 / py .py）")
        }
        let id = UUID()
        let sources: [Source] = sites.compactMap { site in
            guard let key = site["key"] as? String,
                  let name = site["name"] as? String,
                  let apiString = site["api"] as? String else { return nil }
            // Pasted JSON has no base URL: only absolute APIs resolve.
            let api: URL?
            if let base = url {
                api = SubscriptionImporter.resolve(apiString, against: base)
            } else {
                api = URL(string: apiString)
            }
            guard let api else { return nil }
            let type = (site["type"] as? Int) ?? 1
            return Source(id: key, name: name,
                          kind: type == 4 ? .jsonType4 : .jsonType1,
                          api: api,
                          spider: site["spider"] as? String,
                          isSearchable: (site["searchable"] as? Int) != 0,
                          subscriptionID: id.uuidString)
        }
        return Subscription(id: id, name: url?.lastPathComponent ?? "粘贴的订阅", url: url,
                            kind: .tvboxJSON, sources: sources, lastGoodAt: Date())
    }
}
