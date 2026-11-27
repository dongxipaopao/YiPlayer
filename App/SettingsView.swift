import SwiftUI
import UniformTypeIdentifiers

// MARK: - SettingsView + SubscriptionView
// Subscription import (URL paste / local file), multi-subscription list,
// failure keeps the last good config (see SubscriptionStore), and the
// honest v1 capability list: what works, what is a stub.
struct SettingsView: View {
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @EnvironmentObject private var history: HistoryStore
    @State private var urlText = SubscriptionImporter.defaultCatURL.absoluteString
    @State private var isImporting = false
    @State private var importMessage: String?
    @State private var showFilePicker = false
    @State private var showClearHistoryConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                Section("订阅源") {
                    TextField("订阅地址（TVBox JSON / 猫源 .js / .js.md5）", text: $urlText)
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
                Section("关于 v1") {
                    Text("YiPlayer 1.0.0（空壳 v1）\n• 支持：TVBox JSON type 1/4、猫源（JavaScriptCore 有界宿主）\n• 暂不支持：py 源（见下）\n• 不含内置片库、云盘、音乐、漫画、小说")
                        .font(.subheadline)
                    Text("py 源：\(EmbeddedPythonHost.unavailableMessage)")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .fileImporter(isPresented: $showFilePicker,
                          allowedContentTypes: [.json, .plainText, .text],
                          allowsMultipleSelection: false) { result in
                importFromFile(result: result)
            }
        }
    }

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

    private func importFromFile(result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else {
            importMessage = "读取本地文件失败"
            return
        }
        // Security-scoped URL from the file picker: access must be
        // claimed explicitly, or reading fails on a real device.
        guard url.startAccessingSecurityScopedResource() else {
            importMessage = "读取本地文件失败（无权访问该文件）"
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            importMessage = "读取本地文件失败"
            return
        }
        do {
            var sub = try parseSubscription(text: text, url: url)
            sub.localFileName = url.lastPathComponent
            subscriptions.add(sub)
            importMessage = "已导入本地文件「\(url.lastPathComponent)」：\(sub.sources.count) 个源"
        } catch {
            importMessage = "导入失败：\(error.localizedDescription)"
        }
    }

    /// Parse a subscription document into a Subscription.
    /// TVBox JSON -> sources; a cat .js bundle -> one cat source whose
    /// api is the bundle URL (its .md5 is verified at load time).
    private func parseSubscription(text: String, url: URL) throws -> Subscription {
        if url.pathExtension == "md5" || url.lastPathComponent.hasSuffix(".js") {
            let name = url.deletingPathExtension().lastPathComponent
            let source = Source(id: "cat-\(name)", name: name, kind: .cat,
                                api: url, subscriptionID: "cat")
            return Subscription(name: name, url: url, kind: .catBundle, sources: [source])
        }
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sites = json["sites"] as? [[String: Any]] else {
            throw SourceError.parse("无法识别的订阅格式（只支持 TVBox JSON / 猫源 .js / .js.md5）")
        }
        let id = UUID()
        let sources: [Source] = sites.compactMap { site in
            guard let key = site["key"] as? String,
                  let name = site["name"] as? String,
                  let apiString = site["api"] as? String,
                  let api = SubscriptionImporter.resolve(apiString, against: url) else { return nil }
            let type = (site["type"] as? Int) ?? 1
            return Source(id: key, name: name,
                          kind: type == 4 ? .jsonType4 : .jsonType1,
                          api: api,
                          spider: site["spider"] as? String,
                          isSearchable: (site["searchable"] as? Int) != 0,
                          subscriptionID: id.uuidString)
        }
        return Subscription(id: id, name: url.lastPathComponent, url: url,
                            kind: .tvboxJSON, sources: sources, lastGoodAt: Date())
    }
}
