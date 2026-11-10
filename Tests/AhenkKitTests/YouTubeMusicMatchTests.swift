import Foundation
import Testing
@testable import AhenkKit

@Suite("Wallpaper: the song's video as YouTube files it")
struct YouTubeMusicMatchTests {
    private func entry(_ id: String, _ title: String, _ artists: [String], _ duration: TimeInterval?, _ kind: YouTubeMusicEntry.Kind) -> YouTubeMusicEntry {
        YouTubeMusicEntry(id: id, title: title, artists: artists, duration: duration, kind: kind)
    }

    @Test("An official video named after the song beats every upload")
    func named() {
        let entries = [
            entry("fan00000001", "Nova Atlas - Glass Harbor (Lyrics)", ["Some Fan"], 201, .userUpload),
            entry("off00000001", "Glass Harbor", ["Nova Atlas"], 214, .officialVideo),
            entry("off00000002", "Glass Harbor", ["Nova Atlas"], 290, .officialVideo),
        ]
        let found = YouTubeMusicMatcher.officialVideo(among: entries, title: "Glass Harbor (feat. Mira Sol)", artist: "Nova Atlas", duration: 200)
        #expect(found?.id == "off00000001", "the cut closest to the song's length")
    }

    @Test("A session's video is the song's when both artists and the length agree")
    func session() {
        let entries = [
            entry("ses00000001", "Nova Atlas x Mira Sol | Tide Room Session", ["Nova Atlas", "Mira Sol"], 204, .officialVideo),
            entry("fan00000001", "Nova Atlas - Glass Harbor", ["A Channel"], 200, .userUpload),
        ]
        #expect(YouTubeMusicMatcher.officialVideo(among: entries, title: "Glass Harbor", artist: "Nova Atlas, Mira Sol", duration: 200)?.id == "ses00000001")
        #expect(YouTubeMusicMatcher.officialVideo(among: entries, title: "Glass Harbor", artist: "Nova Atlas", duration: 200) == nil, "one artist is not enough without the name")
        #expect(YouTubeMusicMatcher.officialVideo(among: entries, title: "Glass Harbor", artist: "Nova Atlas, Mira Sol", duration: 240) == nil, "nor another length")
    }

    @Test("Another artist's video, another take and another song stay out")
    func others() {
        let entries = [
            entry("oth00000001", "Glass Harbor", ["Juniper Coast"], 200, .officialVideo),
            entry("liv00000001", "Glass Harbor (Live)", ["Nova Atlas"], 205, .officialVideo),
            entry("oth00000002", "Undertow Parade", ["Nova Atlas"], 200, .officialVideo),
            entry("flm00000001", "Glass Harbor (The Film)", ["Nova Atlas"], 900, .officialVideo),
        ]
        #expect(YouTubeMusicMatcher.officialVideo(among: entries, title: "Glass Harbor", artist: "Nova Atlas", duration: 200) == nil)
    }

    @Test("Without a video, the label's recording of the same length")
    func recording() {
        let entries = [
            entry("art00000001", "Glass Harbor (feat. Mira Sol)", ["Nova Atlas"], 201, .artTrack),
            entry("art00000002", "Glass Harbor", ["Nova Atlas"], 260, .artTrack),
            entry("art00000003", "Glass Harbor Nights", ["Nova Atlas"], 200, .artTrack),
        ]
        #expect(YouTubeMusicMatcher.recording(among: entries, title: "Glass Harbor", artist: "Nova Atlas", duration: 200)?.id == "art00000001")
        #expect(YouTubeMusicMatcher.recording(among: entries, title: "Glass Harbor", artist: "Juniper Coast", duration: 200) == nil)
    }

    @Test("Reading an answer: title, artists, length and what YouTube calls it")
    func reading() throws {
        let json = """
        {"contents":[{"musicResponsiveListItemRenderer":{"flexColumns":[
          {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Glass Harbor","navigationEndpoint":{"watchEndpoint":{"videoId":"off00000001",
            "watchEndpointMusicSupportedConfigs":{"watchEndpointMusicConfig":{"musicVideoType":"MUSIC_VIDEO_TYPE_OMV"}}}}}]}}},
          {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Nova Atlas","navigationEndpoint":{"browseEndpoint":{"browseId":"UC1"}}},
            {"text":" & "},{"text":"Mira Sol","navigationEndpoint":{"browseEndpoint":{"browseId":"UC2"}}},{"text":" • "},{"text":"1.2M views"},{"text":" • "},{"text":"3:34"}]}}}
        ]}}]}
        """
        let entries = try #require(YouTubeMusicMatcher.entries(from: Data(json.utf8)))
        #expect(entries == [YouTubeMusicEntry(id: "off00000001", title: "Glass Harbor", artists: ["Nova Atlas", "Mira Sol"], duration: 214, kind: .officialVideo)])
        #expect(YouTubeMusicMatcher.seconds("1:02:03") == 3723 && YouTubeMusicMatcher.seconds("views") == nil)
    }

    @Test("An official video far from the song's length gives way to the song's video on the label's channel")
    func closerUpload() {
        let entries = [
            YouTubeMusicEntry(id: "lab00000001", title: "Kaya X Deniz X Mira - Last Light", artists: ["North Records"], duration: 262, kind: .userUpload),
            YouTubeMusicEntry(id: "omv00000001", title: "Last Light (feat. Deniz)", artists: ["Mira", "Kaya"], duration: 293, kind: .officialVideo),
            YouTubeMusicEntry(id: "lyr00000001", title: "Kaya X Deniz X Mira - Last Light LYRICS", artists: ["someone"], duration: 262, kind: .userUpload),
        ]
        let found = YouTubeMusicMatcher.officialVideo(among: entries, title: "Last Light", artist: "Mira, Kaya, Deniz", duration: 245)
        #expect(found?.id == "lab00000001")
        #expect(found?.kind == .officialVideo)
        // Close enough in length: YouTube's word stands.
        #expect(YouTubeMusicMatcher.officialVideo(among: entries, title: "Last Light", artist: "Mira, Kaya, Deniz", duration: 280)?.id == "omv00000001")
        // A shortened release: the real, longer video stays, although a
        // cut-down copy far below it fits the length.
        let cut = [
            YouTubeMusicEntry(id: "omv00000002", title: "Last Light (feat. Deniz)", artists: ["Mira", "Kaya"], duration: 285, kind: .officialVideo),
            YouTubeMusicEntry(id: "cut00000001", title: "Mira, Kaya, Deniz - Last Light (Clean)", artists: ["somebody"], duration: 226, kind: .userUpload),
        ]
        #expect(YouTubeMusicMatcher.officialVideo(among: cut, title: "Last Light", artist: "Mira, Kaya, Deniz", duration: 229)?.id == "omv00000002")
        // A lyric video or a copy that names one artist of three is not it.
        let weak = [entries[1], entries[2], YouTubeMusicEntry(id: "fan00000001", title: "Mira - Last Light", artists: ["fan"], duration: 262, kind: .userUpload)]
        #expect(YouTubeMusicMatcher.officialVideo(among: weak, title: "Last Light", artist: "Mira, Kaya, Deniz", duration: 245)?.id == "omv00000001")
    }

    @Test("An official video that is a lyric video by its real title gives way to the video's re-upload above it")
    func uploadAbove() {
        let official = YouTubeMusicEntry(id: "omv00000003", title: "Amber (feat. Deniz & Kaya)", artists: ["Mira", "Ada"], duration: 285, kind: .officialVideo)
        let entries = [
            YouTubeMusicEntry(id: "reu00000001", title: "Mira - Amber ft Ada - Deniz - Kaya [KLİP] 2023", artists: ["a fan"], duration: 284, kind: .userUpload),
            YouTubeMusicEntry(id: "rmx00000001", title: "Mira & Ada - Amber (Flute remix)", artists: ["x"], duration: 319, kind: .userUpload),
            official,
            YouTubeMusicEntry(id: "low00000001", title: "Amber - Mira x Ada x Deniz (Official Music Video)", artists: ["y"], duration: 284, kind: .userUpload),
        ]
        #expect(YouTubeMusicMatcher.isNotTheVideo("Mira & Ada & Deniz - Amber (Sözleri/Lyrics)", songTitle: "Amber"))
        #expect(!YouTubeMusicMatcher.isNotTheVideo("Mira - Amber (Official Video)", songTitle: "Amber"))
        let found = YouTubeMusicMatcher.uploadAbove(official, among: entries, title: "Amber", artist: "Mira, Ada, Deniz, Kaya", duration: 229)
        #expect(found?.id == "reu00000001")
        #expect(found?.kind == .officialVideo)
        // Nothing above it: nothing to hand back.
        #expect(YouTubeMusicMatcher.uploadAbove(official, among: Array(entries.dropFirst(2)), title: "Amber", artist: "Mira, Ada, Deniz, Kaya", duration: 229) == nil)
    }
}
