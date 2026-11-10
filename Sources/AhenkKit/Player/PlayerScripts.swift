import Foundation

/// What a play script reports back.
public enum ScriptPlayResult: Hashable, Sendable {
    /// Playing; the app's ID of the song when it says.
    case played(id: String?)
    /// The library (or playlist) has no such song.
    case notFound
    /// The app quit before the script ran.
    case notRunning
    case unreadable

    public static func parse(_ value: ScriptValue) -> ScriptPlayResult {
        let items = value.list ?? [value]
        switch items.first?.text {
        case "played": return .played(id: items.count > 1 ? items[1].text.flatMap { $0.isEmpty ? nil : $0 } : nil)
        case "notfound": return .notFound
        case "notrunning": return .notRunning
        default: return .unreadable
        }
    }
}

/// AppleScript for the desktop player's actions in Apple Music: play a
/// library song (by ID or by title and artist), list and play playlists,
/// read and set the volume. Every script runs only while Music runs (it is
/// never launched by a script) and returns plain values the parsers read.
///
/// Music's scripting has no access to the Apple Music catalog: a song that
/// is not in the library cannot be started by a script. The player opens
/// its catalog page in Music instead (`catalogPageURL`), where one click on
/// Play starts it.
public enum MusicAppScripts {
    static let bundleIdentifier = KnownApps.appleMusic

    /// Plays the library song with this persistent ID (16 hex digits), in
    /// the playlist with `playlistID` when given (Music then goes on
    /// through that playlist).
    public static func playLibraryTrack(persistentID: String, playlistID: String? = nil) -> String? {
        guard isPersistentID(persistentID), playlistID.map(isPersistentID) ?? true else { return nil }
        let container = playlistID.map { "(first user playlist whose persistent ID is \"\($0)\")" } ?? "library playlist 1"
        return script(timeout: 8, """
        try
        \tset t to (first track of \(container) whose persistent ID is "\(persistentID)")
        on error
        \treturn {"notfound"}
        end try
        play t
        return {"played", persistent ID of t}
        """)
    }

    /// Finds the song in the library by title and artist (preferring the
    /// same album) and plays it.
    public static func playLibraryMatch(title: String, artist: String, album: String) -> String {
        let core = SongQuery(title: title, artist: artist, album: album).cleaned
        return script(timeout: 10, """
        try
        \tset found to (search library playlist 1 for \(quoted(core.title)) only songs)
        on error
        \treturn {"notfound"}
        end try
        set best to missing value
        ignoring case and diacriticals
        \trepeat with t in found
        \t\tset n to name of t
        \t\tset a to artist of t
        \t\tif n starts with \(quoted(core.title)) and a is not "" and (a contains \(quoted(core.artist)) or \(quoted(core.artist)) contains a) then
        \t\t\tif best is missing value then set best to contents of t
        \t\t\tif (album of t) starts with \(quoted(core.album)) then
        \t\t\t\tset best to contents of t
        \t\t\t\texit repeat
        \t\t\tend if
        \t\tend if
        \tend repeat
        end ignoring
        if best is missing value then return {"notfound"}
        play best
        return {"played", persistent ID of best}
        """)
    }

    /// The user's playlists (not folders or the built-in lists), at most 100:
    /// `{{name, persistent ID, song count}, …}`.
    public static let playlistsScript = script(timeout: 8, """
    set out to {}
    repeat with p in (every user playlist whose special kind is none)
    \ttry
    \t\tset end of out to {name of p, persistent ID of p, count of tracks of p}
    \tend try
    \tif (count of out) ≥ 100 then exit repeat
    end repeat
    return out
    """, otherwise: "{}")

    /// The first 200 songs of a playlist as five parallel lists.
    public static func playlistSongsScript(playlistID: String) -> String? {
        guard isPersistentID(playlistID) else { return nil }
        return script(timeout: 10, """
        set p to (first user playlist whose persistent ID is "\(playlistID)")
        set n to count of tracks of p
        if n is 0 then return {{}, {}, {}, {}, {}}
        if n > 200 then set n to 200
        return {name of tracks 1 thru n of p, artist of tracks 1 thru n of p, album of tracks 1 thru n of p, duration of tracks 1 thru n of p, persistent ID of tracks 1 thru n of p}
        """, otherwise: "{}")
    }

    public static let volumeScript = script(timeout: 4, "return sound volume", otherwise: "missing value")

    public static func setVolumeScript(_ volume: Double) -> String {
        script(timeout: 4, "set sound volume to \(percent(volume))\nreturn sound volume", otherwise: "missing value")
    }

    /// Music's page of a catalog song (`music://music.apple.com/…?i=…`).
    public static func catalogPageURL(for song: CatalogSong) -> URL? {
        guard let url = song.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host?.hasSuffix("music.apple.com") == true
        else { return nil }
        components.scheme = "music"
        return components.url
    }

    // MARK: Parsing

    public static func parsePlaylists(_ value: ScriptValue) -> [CatalogPlaylist] {
        (value.list ?? []).compactMap { entry in
            guard let fields = entry.list, fields.count >= 3, let name = fields[0].text, !name.isEmpty,
                  let id = fields[1].text, isPersistentID(id)
            else { return nil }
            return CatalogPlaylist(id: "music:playlist:\(id.uppercased())", name: name, songCount: fields[2].number.map { Int($0) })
        }
    }

    public static func parsePlaylistSongs(_ value: ScriptValue) -> [CatalogSong] {
        guard let columns = value.list, columns.count >= 5 else { return [] }
        let names = columns[0].list ?? []
        let artists = columns[1].list ?? []
        let albums = columns[2].list ?? []
        let durations = columns[3].list ?? []
        let ids = columns[4].list ?? []
        let count = [names.count, artists.count, albums.count, durations.count, ids.count].min() ?? 0
        return (0..<count).compactMap { index in
            guard let title = names[index].text, !title.isEmpty, let id = ids[index].text, isPersistentID(id) else { return nil }
            let track = Track(
                id: "music:\(id.uppercased())", source: .appleMusic, title: title,
                artist: artists[index].text ?? "", album: albums[index].text ?? "", duration: durations[index].number ?? 0
            )
            return CatalogSong(playing: track)
        }
    }

    /// 0…1.
    public static func parseVolume(_ value: ScriptValue) -> Double? {
        guard let number = value.number, number.isFinite else { return nil }
        return min(1, max(0, number / 100))
    }

    /// The persistent ID in a playlist ID ("music:playlist:…") or a song
    /// ID ("music:…").
    public static func persistentID(in id: String) -> String? {
        guard let last = id.split(separator: ":").last, id.hasPrefix("music:") else { return nil }
        let text = String(last)
        return isPersistentID(text) ? text.uppercased() : nil
    }

    static func isPersistentID(_ text: String) -> Bool {
        (1...16).contains(text.count) && text.allSatisfy(\.isHexDigit)
    }

    // MARK: Helpers

    static func script(timeout: Int, _ body: String, otherwise: String = #"{"notrunning"}"#) -> String {
        let indented = body.split(separator: "\n", omittingEmptySubsequences: false).map { "\t\t" + $0 }.joined(separator: "\n")
        return ScriptFormatting.ifRunning(bundleIdentifier: bundleIdentifier, otherwise: otherwise, body: """
        with timeout of \(timeout) seconds
        \ttell application id "\(bundleIdentifier)"
        \(indented)
        \tend tell
        end timeout
        """)
    }

    /// An AppleScript string literal: quotes and backslashes escaped,
    /// line breaks and other control characters turned into spaces.
    static func quoted(_ text: String) -> String {
        let flat = String(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) })
        return "\"" + flat.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func percent(_ volume: Double) -> Int {
        Int((min(1, max(0, volume.isFinite ? volume : 0)) * 100).rounded())
    }
}

/// AppleScript for the desktop player's actions in Spotify: play a track
/// (optionally in an album or playlist context) and the volume. Spotify's
/// scripting has no search, queue, playlists or like.
public enum SpotifyAppScripts {
    static let bundleIdentifier = KnownApps.spotify

    /// `play track "spotify:track:…"` (in `context`, a `spotify:album:` or
    /// `spotify:playlist:` URI, when given).
    public static func playTrack(id: String, context: String? = nil) -> String? {
        guard isBase62ID(id) else { return nil }
        var verb = "play track \"spotify:track:\(id)\""
        if let context {
            guard isContextURI(context) else { return nil }
            verb += " in context \"\(context)\""
        }
        return ScriptFormatting.ifRunning(bundleIdentifier: bundleIdentifier, otherwise: #"{"notrunning"}"#, body: """
        with timeout of 6 seconds
        \ttell application id "\(bundleIdentifier)" to \(verb)
        end timeout
        return {"played", "spotify:track:\(id)"}
        """)
    }

    /// What Spotify does right now: `{"state", "playing" | "paused" |
    /// "stopped", the song's URI, seconds into it}`. Asked after
    /// `playTrack`: a Spotify that has only just opened shows the song
    /// without starting it.
    public static let playbackCheckScript = ScriptFormatting.ifRunning(bundleIdentifier: bundleIdentifier, otherwise: #"{"notrunning"}"#, body: """
    with timeout of 4 seconds
    \ttell application id "\(bundleIdentifier)"
    \t\tset currentState to player state as text
    \t\tset currentID to ""
    \t\tset currentPosition to 0
    \t\ttry
    \t\t\tset currentID to id of current track
    \t\t\tset currentPosition to player position
    \t\tend try
    \t\treturn {"state", currentState, currentID, currentPosition as text}
    \tend tell
    end timeout
    """)

    /// `true` when the check says the wanted song (or one that has only
    /// just begun: Spotify may swap in another edition) plays; `nil` when
    /// the answer cannot be read.
    public static func isPlaying(trackID: String, check value: ScriptValue) -> Bool? {
        let items = value.list ?? []
        guard items.count >= 4, items[0].text == "state", let state = items[1].text else { return nil }
        guard state == "playing" else { return false }
        if items[2].text == "spotify:track:\(trackID)" { return true }
        let position = Double((items[3].text ?? "").replacingOccurrences(of: ",", with: ".")) ?? .infinity
        return position < 8
    }

    public static let volumeScript = ScriptFormatting.ifRunning(bundleIdentifier: bundleIdentifier, otherwise: "missing value", body: """
    with timeout of 4 seconds
    \ttell application id "\(bundleIdentifier)" to return sound volume
    end timeout
    """)

    public static func setVolumeScript(_ volume: Double) -> String {
        ScriptFormatting.ifRunning(bundleIdentifier: bundleIdentifier, otherwise: "missing value", body: """
        with timeout of 4 seconds
        \ttell application id "\(bundleIdentifier)" to set sound volume to \(MusicAppScripts.percent(volume))
        end timeout
        return \(MusicAppScripts.percent(volume))
        """)
    }

    /// Spotify's own search for a song it could not be matched to
    /// (`spotify:search:…`): the app shows the results; nothing plays.
    public static func searchURI(for song: CatalogSong) -> URL? {
        let query = SongQuery(song: song).cleaned
        let text = [query.artist, query.title].filter { !$0.isEmpty }.joined(separator: " ")
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        return URL(string: "spotify:search:\(encoded)")
    }

    /// The base-62 track ID in `spotify:track:…`.
    public static func trackID(in uri: String) -> String? {
        guard uri.hasPrefix("spotify:track:") else { return nil }
        let id = String(uri.dropFirst("spotify:track:".count))
        return isBase62ID(id) ? id : nil
    }

    static func isBase62ID(_ text: String) -> Bool {
        text.count == 22 && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    static func isContextURI(_ text: String) -> Bool {
        for prefix in ["spotify:album:", "spotify:playlist:", "spotify:artist:"] where text.hasPrefix(prefix) {
            return isBase62ID(String(text.dropFirst(prefix.count)))
        }
        return false
    }
}
