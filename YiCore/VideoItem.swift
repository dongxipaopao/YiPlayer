import Foundation

// MARK: - VideoItem
// The single model shared by list / detail / search / history.
// Mirrors the CatVod vod_* fields (see 555.py) and the TVBox JSON fields,
// normalised to one shape so call sites never have to know the source type.
public struct VideoItem: Identifiable, Hashable, Codable {
    public var id: String          // vod_id (CatVod) or TVBox vod_id; stable per source
    public var sourceID: String    // which subscription/source produced it
    public var title: String
    public var coverURL: URL?
    public var backdropURL: URL?
    public var year: String?
    public var area: String?
    public var remarks: String?    // vod_remarks, e.g. "更新至第10集" / "HD"
    public var typeName: String?   // vod_type_name, e.g. "电影"
    public var actors: [String]
    public var director: String?
    public var content: String?    // vod_content (synopsis)
    public var rating: Double?
    public var mediaType: MediaType
    public var playFrom: [String]  // vod_play_from, line names, $$$ in CatVod
    public var episodes: [Episode]
    /// Raw play entries per line, parallel to playFrom: playGroups[i][j]
    /// is the "Name$playid" entry for episode j on line i. Kept so
    /// playLines(for:) can resolve every line for one episode number.
    public var playGroups: [[String]]

    public enum MediaType: String, Codable, Hashable {
        case movie, tv, variety, anime, short, unknown
    }

    public init(id: String, sourceID: String, title: String,
                coverURL: URL? = nil, backdropURL: URL? = nil,
                year: String? = nil, area: String? = nil,
                remarks: String? = nil, typeName: String? = nil,
                actors: [String] = [], director: String? = nil,
                content: String? = nil, rating: Double? = nil,
                mediaType: MediaType = .unknown,
                playFrom: [String] = [], episodes: [Episode] = [],
                playGroups: [[String]] = []) {
        self.id = id; self.sourceID = sourceID; self.title = title
        self.coverURL = coverURL; self.backdropURL = backdropURL
        self.year = year; self.area = area; self.remarks = remarks
        self.typeName = typeName; self.actors = actors; self.director = director
        self.content = content; self.rating = rating; self.mediaType = mediaType
        self.playFrom = playFrom; self.episodes = episodes; self.playGroups = playGroups
    }

    /// Spec badges shown on the detail page as plain text
    /// (MarcoMovie-style: "4K / HDR10+ / DV · ATMOS" — text only, no decoding here).
    /// v1 does not know a title's real specs until playback starts; badges are
    /// filled from the stream's AVPlayerItem tracks when known, otherwise empty.
    public var specBadges: [String] { [] }
}
