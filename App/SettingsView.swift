import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - SettingsView + SubscriptionView
// Subscription import, multi-subscription list, failure keeps the last
// good config (see SubscriptionStore), and the honest v2.1 capability list.
//
// Import routes (v2.1 — the user runs YiPlayer inside LiveContainer, so
// no route may depend on the system file picker alone):
//   1. URL: address field + one big, full-width "导入订阅" button.
//   2. In-app file browser (PRIMARY local-file route): lists the files
//      already in the app's Documents / imports / spiders, tap to
//      import. The user drops files there with the system Files app.
//      The system picker stays only as a secondary button — under
//      LiveContainer its rows often cannot be tapped at all.
//   3. Paste subscription TEXT (multi-line box + paste-from-clipboard):
//      TVBox JSON text, a .py spider, or a .js bundle pasted in.
//   4. System file picker (.json / .js / .py / .txt): the picked file
//      is COPIED into the app's own Documents/imports/ first (under
//      security-scoped access), then read from the copy — reading the
//      security-scoped URL directly is unreliable under LiveContainer's
//      sandbox, and a copied file keeps working after the picker closes.
//   5. Every failure shows a concrete reason on screen, never a bare
//      "cancelled": a cancelled picker says so plainly, anything else
//      names the step that failed and points at the paste route.
struct SettingsView: View {
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @EnvironmentObject private var history: HistoryStore
    @State private var urlText = SubscriptionImporter.defaultCatURL.absoluteString
    @State private var pasteText = ""
    @State private var isImporting = false
    @State private var importMessage: String?
    @State private var importMessageIsError = false
    @State private var showFilePicker = false
    @State private var showClearHistoryConfirm = false
    /// Discovered cat sites per source id (from the bundle's /config).
    @State private var catSites: [String: [(key: String, name: String)]] = [:]
    @State private var loadingSitesFor: String?
    /// Files found in the app's Documents (in-app file browser).
    @State private var localFiles: [LocalImportFile] = []

    var body: some View {
        NavigationStack {
            Form {
                subscriptionSection
                subscribedList
                localFileSection
                pasteSection
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
                Section("关于 v2.1") {
                    Text("YiPlayer 2.1.0\n• 支持：TVBox JSON type 1/4、py 源（内嵌 CPython）、猫源（JavaScriptCore 有界宿主 + 内嵌 Node.js 服务端 bundle）\n• 首次打开已预置懂片帝和 9280 猫源，不用先导入\n• 不含内置片库、云盘、音乐、漫画、小说")
                        .font(.subheadline)
                    Text("py 源：内嵌 CPython 3.13 运行 pd.py（懂片帝）。首次调用会慢一些（解释器冷启动），之后正常。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("猫源：9280 那个 Fastify 服务端 bundle 走内嵌 Node.js 26 运行；真正的 websiteBundle 仍走 JavaScriptCore。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .fileImporter(isPresented: $showFilePicker,
                          allowedContentTypes: [.json, UTType(filenameExtension: "js") ?? .sourceCode, .pythonScript, .plainText, .data],
                          allowsMultipleSelection: false) { result in
                importFromFile(result: result)
            }
            .task { refreshLocalFiles() }
        }
    }

    // MARK: - Subscription URL import
    private var subscriptionSection: some View {
        Section {
            Text("订阅地址")
                .font(.caption).foregroundStyle(.secondary)
            TextField("https://…（TVBox JSON / 猫源 .js / .js.md5 / py .py）", text: $urlText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            Button {
                Task { await importFromURL() }
            } label: {
                if isImporting {
                    ProgressView().tint(.white)
                } else {
                    Text("导入订阅").bold()
                }
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
            .disabled(isImporting || urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let importMessage {
                HStack(spacing: 8) {
                    Image(systemName: importMessageIsError ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(importMessageIsError ? .red : .green)
                    Text(importMessage)
                        .font(.footnote)
                        .foregroundStyle(importMessageIsError ? .red : .secondary)
                }
            }
        } header: {
            Text("添加订阅")
        } footer: {
            Text("粘贴订阅地址，点“导入订阅”。也可以用下面的本地文件或粘贴导入。")
        }
    }

    private var subscribedList: some View {
        Section("已导入的订阅") {
            if subscriptions.subscriptions.isEmpty {
                Text("还没有导入订阅。首次打开已预置懂片帝和 9280 猫源。")
                    .font(.subheadline).foregroundStyle(.secondary)
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
    }

    // MARK: - In-app file browser (primary local-file route)
    private var localFileSection: some View {
        Section {
            if localFiles.isEmpty {
                Text("这里还没有文件。")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(localFiles) { file in
                    Button {
                        Task { await importLocalFile(file) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name).font(.subheadline)
                                Text("\(file.folder) · \(Self.formattedSize(file.size)) · \(file.modified.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) { deleteLocalFile(file) }
                    }
                }
            }
            HStack {
                Button("刷新列表") { refreshLocalFiles() }
                Spacer()
                Button("系统文件选择器") { showFilePicker = true }
            }
            .font(.subheadline)
        } header: {
            Text("从本地文件导入")
        } footer: {
            Text("把 .json / .js / .py / .txt 文件放进系统“文件”App → YiPlayer 的 Documents 文件夹（或里面的 imports / spiders 子文件夹），就会出现在这里，点一下就导入。LiveContainer 下系统文件选择器选不中文件时，用这里。")
        }
    }

    private var pasteSection: some View {
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
                setImportMessage("「\(source.name)」没有返回站点列表，将用默认站点 douban。", isError: false)
            }
        } catch {
            setImportMessage("加载「\(source.name)」站点列表失败：\(displayableErrorMessage(error) ?? "已取消")", isError: true)
        }
    }

    private func setImportMessage(_ text: String, isError: Bool) {
        importMessage = text
        importMessageIsError = isError
    }

    // MARK: - URL import
    private func importFromURL() async {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            setImportMessage("地址无效", isError: true)
            return
        }
        isImporting = true
        defer { isImporting = false }
        do {
            let (text, finalURL) = try await SubscriptionImporter.fetch(url: url)
            let sub = try parseSubscription(text: text, url: finalURL)
            subscriptions.add(sub)
            setImportMessage("已导入「\(sub.name)」：\(sub.sources.count) 个源", isError: false)
        } catch {
            if isCancellation(error) { return }
            setImportMessage("导入失败：\(displayableErrorMessage(error) ?? "已取消")（已保留上次可用配置）", isError: true)
        }
    }

    // MARK: - Paste import (no file picker involved)
    private func pasteFromClipboard() {
        if let text = UIPasteboard.general.string, !text.isEmpty {
            pasteText = text
            setImportMessage("已从剪贴板粘贴 \(text.count) 字，点“导入粘贴的文本”。", isError: false)
        } else {
            setImportMessage("剪贴板里没有文本。先去别处复制订阅内容，再回来点这个按钮。", isError: true)
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
            setImportMessage("已导入「\(sub.name)」：\(sub.sources.count) 个源", isError: false)
            pasteText = ""
        } catch {
            if isCancellation(error) { return }
            setImportMessage("粘贴导入失败：\(displayableErrorMessage(error) ?? "已取消")", isError: true)
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

    // MARK: - In-app file browser
    struct LocalImportFile: Identifiable {
        let id = UUID()
        let url: URL
        let name: String
        let folder: String // Documents / imports / spiders
        let size: Int
        let modified: Date
    }

    private static let importableExtensions: Set<String> = ["json", "js", "py", "txt", "md5"]

    private func refreshLocalFiles() {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dirs: [(URL, String)] = [
            (docs, "Documents"),
            (docs.appendingPathComponent("imports", isDirectory: true), "imports"),
            (docs.appendingPathComponent("spiders", isDirectory: true), "spiders"),
        ]
        var found: [LocalImportFile] = []
        for (dir, label) in dirs {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names {
                let url = dir.appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
                guard Self.importableExtensions.contains(url.pathExtension.lowercased()) else { continue }
                let attrs = try? fm.attributesOfItem(atPath: url.path)
                found.append(LocalImportFile(
                    url: url, name: name, folder: label,
                    size: (attrs?[.size] as? Int) ?? 0,
                    modified: (attrs?[.modificationDate] as? Date) ?? Date.distantPast))
            }
        }
        localFiles = found.sorted { $0.modified > $1.modified }
    }

    private static func formattedSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func deleteLocalFile(_ file: LocalImportFile) {
        try? FileManager.default.removeItem(at: file.url)
        refreshLocalFiles()
    }

    private func importLocalFile(_ file: LocalImportFile) async {
        isImporting = true
        defer { isImporting = false }
        importParsedFile(at: file.url, fileName: file.name)
    }

    // MARK: - System file picker (secondary route)
    private func importFromFile(result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            // A cancelled picker is not an error: say so plainly and
            // stop. Anything else names the failure and points at paste.
            if (error as NSError).code == NSUserCancelledError {
                setImportMessage("已取消，未导入任何文件。", isError: false)
            } else {
                setImportMessage("文件导入失败：\(displayableErrorMessage(error) ?? "已取消")。可以改用上方的粘贴导入，把文件内容粘贴进来。", isError: true)
            }
            return
        case .success(let urls):
            guard let url = urls.first else {
                setImportMessage("没有选中文件。", isError: true)
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
            setImportMessage("无法访问这个文件（容器沙盒限制，LiveContainer 下常见）。请改用上方的本地文件浏览或粘贴导入，把文件内容粘贴进来。", isError: true)
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
            setImportMessage("复制文件失败：\(displayableErrorMessage(error) ?? "已取消")。请改用上方的粘贴导入。", isError: true)
            return
        }
        importParsedFile(at: copy, fileName: fileName)
        refreshLocalFiles()
    }

    /// Read an already-local file (in-app browser, or a copy the picker
    /// just made) and turn it into a subscription.
    private func importParsedFile(at url: URL, fileName: String) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            setImportMessage("文件「\(fileName)」不是 UTF-8 文本，无法导入。", isError: true)
            return
        }
        do {
            let sub = try parseSubscription(text: text, url: url, fileName: fileName)
            subscriptions.add(sub)
            setImportMessage("已导入本地文件「\(fileName)」：\(sub.sources.count) 个源", isError: false)
        } catch {
            setImportMessage("导入失败：\(displayableErrorMessage(error) ?? "已取消")（已保留上次可用配置）", isError: true)
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
