import Foundation

// MARK: - Episode
// One playable episode. CatVod play id is "{vod_id}-{sid}-{nid}"
// (see 555.py playerContent): sid = line number, nid = episode number.
// The same shape is used for TVBox JSON episodes (vod_play_url entries).
public struct Episode: Identifiable, Hashable, Codable {
    public var id: String          // "{vod_id}-{sid}-{nid}" for cat/py, or the raw play id
    public var vodID: String
    public var lineIndex: Int      // sid — index into VideoItem.playFrom
    public var number: Int         // nid — episode number (1-based)
    public var name: String        // e.g. "第01集"
    public var playURL: URL?       // direct URL when the source gives one; nil = resolve at play time

    public init(id: String, vodID: String, lineIndex: Int, number: Int,
                name: String, playURL: URL? = nil) {
        self.id = id; self.vodID = vodID; self.lineIndex = lineIndex
        self.number = number; self.name = name; self.playURL = playURL
    }

    /// Groups a long episode list into pages of 50, Rex/MarcoMovie-style.
    public static func grouped(_ episodes: [Episode], pageSize: Int = 50) -> [[Episode]] {
        guard pageSize > 0 else { return [episodes] }
        var out: [[Episode]] = []
        var i = 0
        while i < episodes.count {
            out.append(Array(episodes[i..<min(i + pageSize, episodes.count)]))
            i += pageSize
        }
        return out
    }
}
