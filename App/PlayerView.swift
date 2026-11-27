import SwiftUI

// MARK: - PlayerView (App wrapper)
// Thin wrapper: the real player lives in Player/YiPlayerView.swift.
// Kept as its own file so the App/ layer owns navigation and the
// Player/ layer owns playback.
struct PlayerView: View {
    var item: VideoItem
    var episode: Episode
    var lines: [PlayLine]
    @EnvironmentObject private var history: HistoryStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        YiPlayerView(item: item, episode: episode, lines: lines,
                     history: history) { dismiss() }
    }
}
