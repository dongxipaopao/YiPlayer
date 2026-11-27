import Foundation

// MARK: - PlayLine
// One playback line ("线路") for one episode. A cat/py source returns
// up to ~18 lines for the same episode (555.py: player_aaaa per line);
// the user picks one in the player and can switch without re-entering detail.
public struct PlayLine: Identifiable, Hashable, Codable {
    public var id: String          // "{vod_id}-{sid}-{nid}"
    public var name: String        // line name, e.g. "线路一" / "线路二"
    public var url: URL            // final playable URL (m3u8 / mp4 / flv / mkv)
    public var isDirect: Bool      // true = direct file/m3u8; false = needs client parsing
    public var headers: [String: String]

    public init(id: String, name: String, url: URL,
                isDirect: Bool = true, headers: [String: String] = [:]) {
        self.id = id; self.name = name; self.url = url
        self.isDirect = isDirect; self.headers = headers
    }
}
