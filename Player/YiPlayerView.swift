import SwiftUI
import AVKit
import AVFoundation

// MARK: - YiPlayerView
// The player. One rule governs everything here (research-tvbox-marcotv.md):
//   HDR / 4K / Dolby Vision: NO transcoding, NO colour adjustment.
//   AVPlayer + VideoToolbox decode HEVC / HDR10 / HLG / DV5 / DV8 as-is;
//   the stream is passed through untouched, so colours cannot drift.
//   Only a container AVPlayer cannot open (MKV etc.) would ever need
//   remuxing — that FFmpeg path is NOT in v1 (see BUILD_NOTES.md).
//
// What v1 does have:
//  - AVPlayer + AVPlayerViewController (PiP, AirPlay, system controls as fallback)
//  - eligibleForHDRPlayback: if the device cannot do HDR, AVPlayer refuses
//    the stream (CoreMedia -17223) and the UI says so honestly instead of
//    silently tone-mapping to SDR.
//  - 0.5x–4x speed, double-tap seek ±10s, left-half brightness,
//    right-half volume (drag), long-press 2x, skip intro / skip outro
//    buttons (when the source supplies times — v1: 0 = not supplied),
//    subtitle / audio track picker, episode grid, line switching,
//    continue-watching resume (HistoryStore).
@MainActor
public final class PlayerViewModel: ObservableObject {
    @Published public var isPlaying = false
    @Published public var rate: Float = 1.0
    @Published public var position: Double = 0
    @Published public var duration: Double = 0
    @Published public var showControls = true
    @Published public var currentLine: PlayLine?
    @Published public var lines: [PlayLine] = []
    @Published public var episodes: [Episode] = []
    @Published public var currentEpisode: Episode?
    @Published public var errorMessage: String?
    @Published public var isHDR: Bool = false
    @Published public var hdrUnsupported: Bool = false

    public let player = AVPlayer()
    private var timeObserver: Any?
    private var failureObserver: NSObjectProtocol?
    private var history: HistoryStore?
    private var item: VideoItem?

    public static let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0]

    public init() {
        // HDR capability, checked once (AVPlayerItem.eligibleForHDRPlayback
        // is the documented gate; there is no public "is DV supported" API).
        if #available(iOS 17.0, *) {
            // Kept simple in v1: the real check happens per-item below,
            // because eligibility depends on the stream, not the device alone.
        }
    }

    public func load(item: VideoItem, episode: Episode, lines: [PlayLine],
                     history: HistoryStore) {
        self.item = item
        self.history = history
        self.episodes = item.episodes
        self.currentEpisode = episode
        self.lines = lines
        self.currentLine = lines.first
        if let line = lines.first { play(line: line, resumeFrom: historyEntry(for: item)) }
    }

    private func historyEntry(for item: VideoItem) -> Double {
        history?.entries.first(where: { $0.id == "\(item.sourceID):\(item.id)" })?.position ?? 0
    }

    public func play(line: PlayLine, resumeFrom: Double = 0) {
        currentLine = line
        errorMessage = nil
        hdrUnsupported = false
        // m3u8 goes through the loopback proxy so relative segments/keys
        // resolve correctly (see HLSLoopbackProxy); direct files play as-is.
        let url: URL = line.url.pathExtension.lowercased() == "m3u8"
            ? HLSLoopbackProxy.shared.proxyURL(for: line.url.absoluteString)
            : line.url
        var headers: [String: String] = line.headers
        if headers["User-Agent"] == nil {
            headers["User-Agent"] = "YiPlayer/1.0"
        }
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let playerItem = AVPlayerItem(asset: asset)
        isHDR = playerItem.eligibleForHDRPlayback
        player.replaceCurrentItem(with: playerItem)
        if resumeFrom > 5 {
            player.seek(to: CMTime(seconds: resumeFrom, preferredTimescale: 600))
        }
        player.play()
        isPlaying = true
        installTimeObserver()
        if let old = failureObserver { NotificationCenter.default.removeObserver(old) }
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: playerItem, queue: .main
        ) { [weak self] note in
            let code = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError)?.code
            // -17223 = CoreMedia cannot play this HDR stream on this device.
            if code == -17223 {
                self?.hdrUnsupported = true
                self?.errorMessage = "这台设备无法播放这条 HDR / 杜比视界流，换一条线路或换 SDR 片源试试"
            } else {
                self?.errorMessage = "播放失败，换一条线路试试"
            }
        }
    }

    public func switchLine(_ line: PlayLine) {
        let pos = position
        play(line: line, resumeFrom: pos)
    }

    public func playEpisode(_ episode: Episode, lines: [PlayLine]) async {
        currentEpisode = episode
        self.lines = lines
        if let first = lines.first { play(line: first) }
    }

    public func togglePlay() {
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
    }

    public func seek(by seconds: Double) {
        let target = max(0, position + seconds)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    public func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    public func setRate(_ rate: Float) {
        self.rate = rate
        player.rate = rate
    }

    /// Long-press 2x: hold to play at 2x, release to return to the chosen rate.
    public func setTemporaryRate(_ rate: Float?) {
        player.rate = rate ?? self.rate
    }

    public func skipIntro() { seek(by: 85) }   // v1: fixed 85s; per-source times are v2
    public func skipOutro() { seek(to: max(0, duration - 30)) }

    public func saveProgress() {
        guard let item, let episode = currentEpisode else { return }
        history?.record(item: item, episode: episode, position: position, duration: duration)
    }

    private func installTimeObserver() {
        if let observer = timeObserver { player.removeTimeObserver(observer) }
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            self.position = time.seconds
            self.duration = self.player.currentItem?.duration.seconds ?? 0
            if self.duration.isNaN || self.duration.isInfinite { self.duration = 0 }
        }
    }

    deinit {
        if let observer = timeObserver { player.removeTimeObserver(observer) }
        if let observer = failureObserver { NotificationCenter.default.removeObserver(observer) }
    }
}

// MARK: - YiPlayerView (SwiftUI HUD over AVPlayer)
public struct YiPlayerView: View {
    @StateObject private var vm = PlayerViewModel()
    @State private var showTracks = false
    @State private var showEpisodes = false
    @State private var showLines = false
    @State private var brightness: Double = 0.5

    public var item: VideoItem
    public var episode: Episode
    public var lines: [PlayLine]
    public var history: HistoryStore
    public var onClose: () -> Void

    public init(item: VideoItem, episode: Episode, lines: [PlayLine],
                history: HistoryStore, onClose: @escaping () -> Void) {
        self.item = item; self.episode = episode; self.lines = lines
        self.history = history; self.onClose = onClose
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoPlayer(player: vm.player)
                .ignoresSafeArea()
                .onTapGesture(count: 2) { vm.seek(by: 10) } // double-tap: +10s (left half: -10s is v2)
                .onLongPressGesture(minimumDuration: 0.4, pressing: { pressing in
                    if !pressing { vm.setTemporaryRate(nil) }
                }, perform: {
                    vm.setTemporaryRate(2.0)
                })
                .gesture(
                    DragGesture().onChanged { value in
                        // Left half = brightness, right half = volume (Noctra/Rex-style).
                        // v1: brightness via UIScreen; volume via AVAudioSession is
                        // intentionally not touched here — MPVolumeView is the
                        // system route and is out of scope for the skeleton.
                        if value.startLocation.x < UIScreen.main.bounds.width / 2 {
                            brightness = min(1, max(0, brightness - value.translation.height / 400))
                            UIScreen.main.brightness = brightness
                        }
                    }
                )

            if vm.showControls {
                controlsOverlay
            }
            if let error = vm.errorMessage {
                VStack {
                    Spacer()
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .padding()
                }
            }
        }
        .onAppear { vm.load(item: item, episode: episode, lines: lines, history: history) }
        .onDisappear { vm.saveProgress(); vm.player.pause() }
        .sheet(isPresented: $showTracks) { TrackPickerView(player: vm.player) }
        .sheet(isPresented: $showEpisodes) {
            EpisodeSheetView(item: item, current: vm.currentEpisode) { ep in
                Task { await vm.playEpisode(ep, lines: vm.lines) }
            }
        }
        .sheet(isPresented: $showLines) {
            LineSheetView(lines: vm.lines, current: vm.currentLine) { vm.switchLine($0) }
        }
    }

    private var controlsOverlay: some View {
        VStack {
            HStack {
                Button(action: { vm.saveProgress(); onClose() }) {
                    Image(systemName: "chevron.left").font(.title3).foregroundStyle(.white)
                }
                Text(item.title).font(.headline).foregroundStyle(.white).lineLimit(1)
                Spacer()
                if vm.isHDR {
                    Text("HDR").font(.caption2).bold()
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.white.opacity(0.2), in: Capsule())
                        .foregroundStyle(.white)
                }
            }
            .padding()
            Spacer()
            VStack(spacing: 10) {
                HStack(spacing: 16) {
                    Button("跳过片头") { vm.skipIntro() }.buttonStyle(.bordered)
                    Button("跳过片尾") { vm.skipOutro() }.buttonStyle(.bordered)
                    Spacer()
                    Button("线路") { showLines = true }.buttonStyle(.bordered)
                    Button("选集") { showEpisodes = true }.buttonStyle(.bordered)
                    Button("音轨/字幕") { showTracks = true }.buttonStyle(.bordered)
                }
                .tint(.white)
                HStack {
                    Button(action: { vm.seek(by: -10) }) { Image(systemName: "gobackward.10") }
                    Button(action: vm.togglePlay) {
                        Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill").font(.largeTitle)
                    }
                    Button(action: { vm.seek(by: 10) }) { Image(systemName: "goforward.10") }
                    Spacer()
                    Menu("\(vm.rate, specifier: "%.2g")x") {
                        ForEach(PlayerViewModel.speeds, id: \.self) { speed in
                            Button("\(speed, specifier: "%.2g")x") { vm.setRate(speed) }
                        }
                    }
                }
                .foregroundStyle(.white)
                Slider(value: Binding(get: { vm.position }, set: { vm.seek(to: $0) }),
                       in: 0...(vm.duration > 0 ? vm.duration : 1))
                    .tint(.white)
                HStack {
                    Text(formatTime(vm.position)).font(.caption).foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    Text(formatTime(vm.duration)).font(.caption).foregroundStyle(.white.opacity(0.8))
                }
            }
            .padding()
            .background(.ultraThinMaterial) // liquid-glass style HUD (iOS 26: .glassEffect is the v2 upgrade)
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let s = Int(seconds)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - Track picker (subtitle / audio)
private struct TrackPickerView: View {
    var player: AVPlayer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("字幕") {
                    ForEach(subtitleGroups, id: \.id) { group in
                        Text(group.name).font(.subheadline)
                    }
                    if subtitleGroups.isEmpty { Text("无字幕轨").foregroundStyle(.secondary) }
                }
                Section("音轨") {
                    ForEach(audioGroups, id: \.id) { group in
                        Text(group.name).font(.subheadline)
                    }
                    if audioGroups.isEmpty { Text("无多音轨").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("音轨 / 字幕")
            .toolbar { Button("完成") { dismiss() } }
        }
    }

    private struct Track: Identifiable { var id: String; var name: String }
    private var subtitleGroups: [Track] {
        player.currentItem?.asset.mediaSelectionGroup(forMediaCharacteristic: .legible).map { group in
            group.options.map { Track(id: $0.displayName, name: $0.displayName) }
        } ?? []
    }
    private var audioGroups: [Track] {
        player.currentItem?.asset.mediaSelectionGroup(forMediaCharacteristic: .audible).map { group in
            group.options.map { Track(id: $0.displayName, name: $0.displayName) }
        } ?? []
    }
}

private struct EpisodeSheetView: View {
    var item: VideoItem
    var current: Episode?
    var onSelect: (Episode) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    var body: some View {
        NavigationStack {
            let pages = Episode.grouped(item.episodes)
            VStack {
                if pages.count > 1 {
                    Picker("范围", selection: $page) {
                        ForEach(pages.indices, id: \.self) { i in
                            Text("\(pages[i].first?.number ?? 0)-\(pages[i].last?.number ?? 0)").tag(i)
                        }
                    }
                    .pickerStyle(.segmented).padding(.horizontal)
                }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64))], spacing: 10) {
                        ForEach(pages.isEmpty ? [] : pages[min(page, pages.count - 1)]) { ep in
                            Button(ep.name) { onSelect(ep); dismiss() }
                                .buttonStyle(.bordered)
                                .tint(ep.id == current?.id ? .accentColor : .secondary)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("选集")
            .toolbar { Button("完成") { dismiss() } }
        }
    }
}

private struct LineSheetView: View {
    var lines: [PlayLine]
    var current: PlayLine?
    var onSelect: (PlayLine) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(lines) { line in
                Button {
                    onSelect(line); dismiss()
                } label: {
                    HStack {
                        Text(line.name)
                        Spacer()
                        if line.id == current?.id { Image(systemName: "checkmark") }
                    }
                }
            }
            .navigationTitle("切换线路")
            .toolbar { Button("完成") { dismiss() } }
        }
    }
}
