import Foundation

/// A search result with its score (higher is better).
public struct RankedVideo: Hashable, Sendable {
    public var video: YouTubeVideo
    public var score: Double

    public init(video: YouTubeVideo, score: Double) {
        self.video = video
        self.score = score
    }
}

/// Picks real music videos out of YouTube's search results, for the song
/// and for its artist. Search returns plenty that is not a video worth
/// showing (the cover over the audio, lyric videos, fan uploads of the
/// audio, live streams, unrelated popular videos), so a candidate must:
///
/// - name the song (its core title, as whole words) and the artist (in the
///   title, or the channel is the artist's own: "Artist", "ArtistVEVO",
///   "Artist Official", the official artist channel badge);
/// - not be an art track (YouTube's "Provided to YouTube by …" uploads,
///   "- Topic" channels, an artist channel's upload titled just the track
///   name), a live stream, audio, lyrics, karaoke, a loop, a reaction, a
///   cover lesson or another edit (slowed, sped up, 8D, nightcore);
/// - say it is a video: an "official video" style marker (several
///   languages), or the artist's official channel or VEVO.
///
/// Then it scores: official markers and channels up, live versions,
/// remixes, acoustic takes and covers down, a length close to the song's up
/// (music videos often add an intro or an outro, so a longer video costs
/// less than a shorter one), and views as a small tie-breaker.
public enum VideoRanking {
    /// Lower scores are not taken as the song's own video.
    public static let songVideoThreshold = 3.0

    /// The song's own video among `videos`, best first.
    public static func songVideos(_ videos: [YouTubeVideo], title: String, artist: String, duration: TimeInterval?) -> [RankedVideo] {
        let core = TrackMatching.coreTitle(title)
        let names = artistNames(artist)
        guard !core.isEmpty, !names.isEmpty else { return [] }
        let songWords = Set(core.split(separator: " ").map(String.init))
        var ranked: [(RankedVideo, Int)] = []
        for (index, video) in unique(videos).enumerated() {
            let text = TrackMatching.normalized(video.title)
            guard contains(words: core, in: text) else { continue }
            let channel = channelMatch(video.channel, names: names)
            let artistInTitle = names.contains { contains(words: $0, in: text) }
            let ownChannel = channel.isOwn(official: video.isOfficialArtistChannel)
            guard artistInTitle || ownChannel else { continue }
            guard !video.isArtTrack, !video.isLive, !channel.isTopic else { continue }
            // What the title says beyond the song and the artist.
            let rest = remainder(of: text, removing: [core] + names)
            guard !hasHardNegative(rest, allowedWords: songWords) else { continue }
            let marker = markerStrength(rest)
            // An artist channel's upload named only after the track is
            // YouTube's art track without its description.
            if marker == 0, text == core { continue }
            // YouTube's official artist badge counts for this artist's
            // channel only: a producer's or another artist's channel has
            // the badge too, and its mashup of the song is not the video.
            let officialOwn = video.isOfficialArtistChannel && (channel.isArtist || channel.sharesName)
            let official = officialOwn || channel.isVEVO
            guard marker > 0 || official || isVisualizer(rest) else { continue }
            if let length = video.duration, length < 45 { continue }

            var score = 2.0 + marker
            if ownChannel { score += 1.5 }
            if officialOwn { score += 1.5 }
            if channel.isVEVO { score += 1.5 }
            if video.isVerifiedChannel, !video.isOfficialArtistChannel { score += 0.3 }
            if artistInTitle { score += 0.5 }
            score += durationScore(video: video.duration, song: duration)
            score += softPenalty(rest, allowedWords: songWords)
            score += viewBonus(video.viewCount, weight: 0.1)
            guard score >= songVideoThreshold else { continue }
            ranked.append((RankedVideo(video: video, score: score), index))
        }
        return ordered(ranked)
    }

    /// Words that only say "this upload is the recording, not a clip":
    /// fine for `songUploads`.
    static let recordingWords: Set<String> = [
        "official audio", "audio", "audio only", "lyric", "lyrics", "lyric video", "sozleri", "letra", "paroles", "testo",
    ]

    /// The song's own uploads when it has no video of its own: the label's
    /// art track, an "official audio", a lyric video. A still picture of
    /// the right song is better than a video of another one. Same song and
    /// artist as `songVideos`; other takes (covers, karaoke, sped-up or
    /// slowed edits, live) stay out. Best first.
    public static func songUploads(_ videos: [YouTubeVideo], title: String, artist: String, duration: TimeInterval?) -> [RankedVideo] {
        let core = TrackMatching.coreTitle(title)
        let names = artistNames(artist)
        guard !core.isEmpty, !names.isEmpty else { return [] }
        let songWords = Set(core.split(separator: " ").map(String.init))
        var ranked: [(RankedVideo, Int)] = []
        for (index, video) in unique(videos).enumerated() {
            let text = TrackMatching.normalized(video.title)
            guard contains(words: core, in: text), !video.isLive else { continue }
            let channel = channelMatch(video.channel, names: names)
            let artistInTitle = names.contains { contains(words: $0, in: text) }
            let ownChannel = channel.isOwn(official: video.isOfficialArtistChannel) || channel.isTopic
            guard artistInTitle || ownChannel else { continue }
            let rest = remainder(of: text, removing: [core] + names)
            guard !hasHardNegative(rest, allowedWords: songWords.union(recordingWords)) else { continue }
            if let length = video.duration {
                guard length >= 45 else { continue }
                // Another cut or a mix, not this recording.
                if let duration, duration > 0, abs(length - duration) > 45 { continue }
            }
            var score = durationScore(video: video.duration, song: duration)
            // The artist's own upload first, a fan's copy last.
            if ownChannel { score += 3 }
            if video.isOfficialArtistChannel { score += 1.5 }
            if video.isArtTrack { score += 1 }
            if artistInTitle { score += 0.5 }
            score += softPenalty(rest, allowedWords: songWords)
            score += viewBonus(video.viewCount, weight: 0.1)
            ranked.append((RankedVideo(video: video, score: score), index))
        }
        return ordered(ranked)
    }

    /// The song's video under another name: a session or a series titles
    /// its upload after itself ("Artist | Some Session"), not after the
    /// song. Among the first results of a search for the song, a video that
    /// names the artist, is watched a lot and runs exactly as long as the
    /// song is that recording. Videos that do name the song are left to
    /// `songVideos` and `songUploads`.
    public static func songVideosByLength(
        _ videos: [YouTubeVideo], title: String, artist: String, duration: TimeInterval?, among first: Int = 4
    ) -> [RankedVideo] {
        let core = TrackMatching.coreTitle(title)
        let names = artistNames(artist)
        guard let duration, duration > 30, !core.isEmpty, !names.isEmpty else { return [] }
        var ranked: [(RankedVideo, Int)] = []
        for (index, video) in unique(videos).prefix(max(0, first)).enumerated() {
            let text = TrackMatching.normalized(video.title)
            guard !contains(words: core, in: text), !video.isLive, !video.isArtTrack else { continue }
            guard let length = video.duration, abs(length - duration) <= 6 else { continue }
            guard (video.viewCount ?? 0) >= 50_000 else { continue }
            let channel = channelMatch(video.channel, names: names)
            guard names.contains(where: { contains(words: $0, in: text) }) || channel.isArtist || channel.sharesName else { continue }
            guard !hasHardNegative(remainder(of: text, removing: names), allowedWords: []) else { continue }
            ranked.append((RankedVideo(video: video, score: 3 + viewBonus(video.viewCount, weight: 0.2) - Double(index) * 0.2), index))
        }
        return ordered(ranked)
    }

    /// Other videos by `artist` among `videos`, best first: from the
    /// artist's own channel (or naming the artist with an official video
    /// marker), never one of `excluding` (the song's own videos) or another
    /// upload of the song itself.
    public static func artistVideos(
        _ videos: [YouTubeVideo], artist: String, excluding: Set<String> = [], songTitle: String? = nil, limit: Int = 5
    ) -> [RankedVideo] {
        let names = artistNames(artist)
        guard !names.isEmpty else { return [] }
        let song = songTitle.map(TrackMatching.coreTitle) ?? ""
        var ranked: [(RankedVideo, Int)] = []
        var titles: Set<String> = []
        for (index, video) in unique(videos).enumerated() where !excluding.contains(video.id) {
            let text = TrackMatching.normalized(video.title)
            if !song.isEmpty, contains(words: song, in: text) { continue }
            let channel = channelMatch(video.channel, names: names)
            let artistInTitle = names.contains { contains(words: $0, in: text) }
            guard !video.isArtTrack, !video.isLive, !channel.isTopic else { continue }
            let rest = remainder(of: text, removing: names)
            guard !hasHardNegative(rest, allowedWords: []) else { continue }
            let marker = markerStrength(rest)
            let official = video.isOfficialArtistChannel || channel.isVEVO
            // A title that is only a track name is an art track.
            guard marker > 0 || artistInTitle else { continue }
            // On another channel the artist has to be the one performing
            // ("Artist - Song", "… feat. Artist"), not a word of the song's
            // name: an artist called "Jefe" is not in "Someone - El Jefe".
            let ownChannel = channel.isOwn(official: video.isOfficialArtistChannel)
            guard ownChannel || (marker > 0 && isPerformer(names, inTitle: video.title)) else { continue }
            guard marker > 0 || official || isVisualizer(rest) else { continue }
            if let length = video.duration, !(60...900).contains(length) { continue }
            // One upload per title (re-uploads, regional copies).
            let core = remainder(of: rest, removing: strongMarkers + weakMarkers)
            guard titles.insert(core).inserted else { continue }

            var score = marker
            if video.isOfficialArtistChannel { score += 1.5 }
            if channel.isVEVO { score += 1.5 }
            if ownChannel { score += 1 }
            score += softPenalty(rest, allowedWords: [])
            score += viewBonus(video.viewCount, weight: 0.2)
            ranked.append((RankedVideo(video: video, score: score), index))
        }
        return Array(ordered(ranked).prefix(max(0, limit)))
    }

    /// Whether one of `names` performs in a video titled `title`: named
    /// before the dash ("Artist - Song", "A, Artist & B - Song") or as a
    /// guest ("Song (feat. Artist)").
    static func isPerformer(_ names: [String], inTitle title: String) -> Bool {
        var head: String?
        for separator in [" - ", " \u{2013} ", " \u{2014} ", " | ", ": "] {
            if let range = title.range(of: separator) {
                let candidate = String(title[..<range.lowerBound])
                if head == nil || candidate.count < (head?.count ?? .max) { head = candidate }
            }
        }
        let text = TrackMatching.normalized(title)
        let performers = head.map(TrackMatching.normalized) ?? ""
        return names.contains { name in
            if !performers.isEmpty, contains(words: name, in: performers) { return true }
            return ["feat", "ft", "featuring", "with", "x"].contains { contains(words: "\($0) \(name)", in: text) }
        }
    }

    // MARK: Names

    /// The artist as given and its parts ("A & B feat. C" → "a and b feat c",
    /// "a", "b", "c"), normalized; the first is the whole string.
    public static func artistNames(_ artist: String) -> [String] {
        let full = TrackMatching.normalized(artist)
        guard !full.isEmpty else { return [] }
        let separators = #"\s*(?:,|&|/|;|\+|\s(?:x|feat\.?|ft\.?|featuring|with|and|vs\.?)\s)\s*"#
        let parts = artist.replacingOccurrences(of: separators, with: "\u{1F}", options: [.regularExpression, .caseInsensitive])
            .split(separator: "\u{1F}")
            .map { TrackMatching.normalized(String($0)) }
            .filter { $0.count >= 2 }
        var names = [full]
        for part in parts where !names.contains(part) { names.append(part) }
        return names
    }

    struct ChannelMatch {
        var isArtist = false
        var isVEVO = false
        /// "Artist - Topic": YouTube's art tracks.
        var isTopic = false
        /// The channel's name holds the artist's ("EL NAME", "ABC and
        /// Artist Name"): theirs when YouTube also marks it as an
        /// official artist channel.
        var sharesName = false

        /// The artist's own channel, for a video YouTube marks (or not)
        /// as from an official artist channel.
        func isOwn(official: Bool) -> Bool {
            isArtist || (sharesName && official)
        }
    }

    /// Whether `channel` is one of the artist's own: "Artist", "ArtistVEVO",
    /// "Artist Official", "Artist Music", or "Artist - Topic".
    static func channelMatch(_ channel: String, names: [String]) -> ChannelMatch {
        let normalized = TrackMatching.normalized(channel)
        guard !normalized.isEmpty else { return ChannelMatch() }
        let squeezed = normalized.replacingOccurrences(of: " ", with: "")
        var match = ChannelMatch()
        for name in names {
            let tight = name.replacingOccurrences(of: " ", with: "")
            if name.count >= 3, contains(words: name, in: normalized) { match.sharesName = true }
            if normalized == name || squeezed == tight {
                match.isArtist = true
            } else if squeezed == tight + "vevo" {
                match.isArtist = true
                match.isVEVO = true
            } else if normalized == name + " topic" {
                match.isTopic = true
            } else if ["official", "music", "tv", "band", "channel"].contains(where: { squeezed == tight + $0 }) {
                match.isArtist = true
            }
        }
        return match
    }

    // MARK: Markers

    /// "This is the music video", in the languages songs are often titled in.
    static let strongMarkers = [
        "official music video", "official video", "music video", "official mv", "official clip", "official 4k video",
        "official hd video", "video oficial", "videoclip oficial", "videoclip", "video clip", "clip officiel", "clip oficial",
        "offizielles musikvideo", "musikvideo", "resmi video", "resmi klip", "video ufficiale", "mv", "m v",
    ]

    /// Weaker hints of a video ("Artist - Song (Video)").
    static let weakMarkers = ["full video", "hd video", "4k video", "video", "clip", "klip"]

    /// Not a video worth showing (audio over a still, text, edits, loops).
    static let hardNegatives = [
        "official audio", "audio", "audio only", "lyric", "lyrics", "lyric video", "sozleri", "letra", "paroles", "testo",
        "karaoke", "instrumental", "8d", "slowed", "sped up", "speed up", "nightcore", "reverb", "bass boosted",
        "1 hour", "one hour", "10 hours", "hour version", "loop", "reaction", "reacts", "tutorial", "lesson", "how to play",
        "piano cover", "guitar cover", "drum cover", "cover by", "fan made", "fanmade", "teaser", "trailer", "snippet",
        "preview", "full album", "album stream", "shorts",
        // Translations and instrumentals of the song, in Turkish and English.
        "ceviri", "cevirisi", "translation", "beat", "type beat",
    ]

    /// Another take of the song: shown, but after the real one.
    static let softNegatives: [(String, Double)] = [
        ("live", -1.5), ("concert", -1.5), ("acoustic", -1), ("remix", -1.5), ("cover", -2), ("version", -0.5),
        ("behind the scenes", -2), ("making of", -2), ("dance practice", -1), ("performance video", -0.5),
        ("visualizer", -0.5), ("visualiser", -0.5), ("edit", -0.3),
        // Turkish: live, acoustic, version.
        ("canli", -1.5), ("akustik", -1), ("versiyon", -0.5),
    ]

    /// 3 for an official video marker, 1.5 for a plain "video", else 0.
    static func markerStrength(_ text: String) -> Double {
        if strongMarkers.contains(where: { contains(words: $0, in: text) }) { return 3 }
        if weakMarkers.contains(where: { contains(words: $0, in: text) }) { return 1.5 }
        return 0
    }

    static func isVisualizer(_ text: String) -> Bool {
        contains(words: "visualizer", in: text) || contains(words: "visualiser", in: text)
    }

    static func hasHardNegative(_ text: String, allowedWords: Set<String>) -> Bool {
        hardNegatives.contains { marker in
            !allowedWords.contains(marker) && contains(words: marker, in: text)
        }
    }

    static func softPenalty(_ text: String, allowedWords: Set<String>) -> Double {
        softNegatives.reduce(0) { total, item in
            !allowedWords.contains(item.0) && contains(words: item.0, in: text) ? total + item.1 : total
        }
    }

    /// Music videos run about as long as the song, often with an intro or
    /// an outro; a much shorter or much longer one is another cut.
    static func durationScore(video: TimeInterval?, song: TimeInterval?) -> Double {
        guard let video, let song, song > 0 else { return 0 }
        let difference = video - song
        let distance = abs(difference)
        if distance <= 6 { return 2 }
        if distance <= 20 { return 1.2 }
        if difference > 0, difference <= 90 { return 0.4 }
        if distance <= 45 { return 0.3 }
        if distance > 240 { return -3 }
        return -1
    }

    static func viewBonus(_ views: Int?, weight: Double) -> Double {
        guard let views, views > 0 else { return 0 }
        return log10(Double(views)) * weight
    }

    // MARK: Text

    /// True when every word of `needle` appears in `haystack`, in order and
    /// as whole words.
    static func contains(words needle: String, in haystack: String) -> Bool {
        guard !needle.isEmpty, !haystack.isEmpty else { return false }
        return (" " + haystack + " ").contains(" " + needle + " ")
    }

    /// `text` with each of `parts` taken out once (as whole words).
    static func remainder(of text: String, removing parts: [String]) -> String {
        var padded = " " + text + " "
        for part in parts.sorted(by: { $0.count > $1.count }) where !part.isEmpty {
            if let range = padded.range(of: " " + part + " ") {
                padded.replaceSubrange(range, with: " ")
            }
        }
        return padded.split(separator: " ").joined(separator: " ")
    }

    private static func unique(_ videos: [YouTubeVideo]) -> [YouTubeVideo] {
        var seen: Set<String> = []
        return videos.filter { seen.insert($0.id).inserted }
    }

    /// Best score first; ties keep YouTube's order.
    private static func ordered(_ ranked: [(RankedVideo, Int)]) -> [RankedVideo] {
        ranked.sorted { $0.0.score != $1.0.score ? $0.0.score > $1.0.score : $0.1 < $1.1 }.map(\.0)
    }
}
