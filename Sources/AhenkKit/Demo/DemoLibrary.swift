import Foundation

/// The demo's whole invented music world: six artists with their albums,
/// EPs and singles, playlists, generated covers and invented lyric lines,
/// so the desktop player (cover flow, search, album and artist pages,
/// playlists, the queue) can be used and screenshotted offline.
///
/// Every name and line here was written for Ahenk. The four songs of
/// `DemoCatalog` (the playlist the demo starts with) belong to albums here.
public struct DemoLibrary: Sendable {
    public let artists: [CatalogArtist]
    /// Every release, by artist and then oldest first.
    public let albums: [CatalogAlbum]
    /// Every playable song.
    public let songs: [DemoSong]
    public let playlists: [CatalogPlaylist]

    private let songsByID: [String: DemoSong]
    private let catalogSongsByID: [String: CatalogSong]
    private let songIDsByAlbum: [String: [String]]
    private let songIDsByPlaylist: [String: [String]]

    public static let standard = DemoLibrary()

    public init() {
        var artists: [CatalogArtist] = []
        var albums: [CatalogAlbum] = []
        var songs: [DemoSong] = []
        var catalogSongs: [String: CatalogSong] = [:]
        var byAlbum: [String: [String]] = [:]
        for artistSpec in Self.artistSpecs {
            let artist = CatalogArtist(id: "demo:artist:\(artistSpec.slug)", name: artistSpec.name, genre: artistSpec.genre)
            artists.append(artist)
            for release in artistSpec.releases {
                let albumID = "demo:album:\(release.slug)"
                let original = release.original.map { DemoCatalog.songs[$0] }
                let colors = original?.palette.colors ?? release.colors.compactMap(SRGBColor.init(hex:))
                let seed = original?.artworkSeed ?? release.seed
                let palette = original?.palette ?? Palette(colors: colors)
                var releaseSongs: [DemoSong] = []
                if let original { releaseSongs.append(original) }
                for spec in release.songs {
                    releaseSongs.append(DemoSong(
                        track: Track(
                            id: "demo:\(spec.slug)", source: .demo, title: spec.title, artist: artistSpec.name,
                            album: release.title, duration: spec.duration
                        ),
                        year: release.year, palette: palette, artworkSeed: seed,
                        lyrics: Self.lyrics(seed: seed &+ UInt64(releaseSongs.count) &* 7_919, duration: spec.duration, turkish: artistSpec.turkish)
                    ))
                }
                let artwork = CatalogArtwork.generated(seed: seed, colors: colors)
                albums.append(CatalogAlbum(
                    id: albumID, title: release.title, artistName: artistSpec.name, artistID: artist.id,
                    releaseDate: Self.date(year: release.year, month: release.month), trackCount: releaseSongs.count,
                    kind: release.kind, artwork: artwork
                ))
                for (index, song) in releaseSongs.enumerated() {
                    catalogSongs[song.track.id] = CatalogSong(
                        id: song.track.id, title: song.track.title, artistName: song.track.artist, albumTitle: release.title,
                        albumID: albumID, artistID: artist.id, duration: song.track.duration, trackNumber: index + 1,
                        discNumber: 1, artwork: artwork, origin: song.track
                    )
                }
                byAlbum[albumID] = releaseSongs.map(\.track.id)
                songs.append(contentsOf: releaseSongs)
            }
        }
        var playlists: [CatalogPlaylist] = []
        var byPlaylist: [String: [String]] = [:]
        for spec in Self.playlistSpecs {
            let ids = spec.songs.map { "demo:\($0)" }.filter { catalogSongs[$0] != nil }
            let id = "demo:playlist:\(spec.slug)"
            let first = ids.first.flatMap { catalogSongs[$0]?.artwork }
            playlists.append(CatalogPlaylist(id: id, name: spec.name, songCount: ids.count, artwork: first))
            byPlaylist[id] = ids
        }
        self.artists = artists
        self.albums = albums
        self.songs = songs
        self.playlists = playlists
        songsByID = Dictionary(uniqueKeysWithValues: songs.map { ($0.track.id, $0) })
        catalogSongsByID = catalogSongs
        songIDsByAlbum = byAlbum
        songIDsByPlaylist = byPlaylist
    }

    // MARK: Lookups

    public func demoSong(id: String) -> DemoSong? {
        songsByID[id]
    }

    public func catalogSong(id: String) -> CatalogSong? {
        catalogSongsByID[id]
    }

    public var catalogSongs: [CatalogSong] {
        songs.compactMap { catalogSongsByID[$0.track.id] }
    }

    public func songs(ofAlbum id: String) -> [CatalogSong] {
        (songIDsByAlbum[id] ?? []).compactMap { catalogSongsByID[$0] }
    }

    public func songs(ofPlaylist id: String) -> [CatalogSong] {
        (songIDsByPlaylist[id] ?? []).compactMap { catalogSongsByID[$0] }
    }

    public func albums(ofArtist id: String) -> [CatalogAlbum] {
        albums.filter { $0.artistID == id }
    }

    public func artist(named name: String) -> CatalogArtist? {
        let wanted = TrackMatching.normalized(name)
        return artists.first { TrackMatching.normalized($0.name) == wanted }
    }

    // MARK: Invented content

    private struct ArtistSpec {
        var slug: String
        var name: String
        var genre: String
        var turkish = false
        var releases: [ReleaseSpec]
    }

    private struct ReleaseSpec {
        var slug: String
        var title: String
        var kind: AlbumKind = .album
        var year: Int
        var month = 6
        var seed: UInt64 = 0
        var colors: [String] = []
        /// Index into `DemoCatalog.songs`: that song opens the release and
        /// gives it its cover.
        var original: Int?
        var songs: [SongSpec]
    }

    private struct SongSpec {
        var slug: String
        var title: String
        var duration: TimeInterval

        init(_ slug: String, _ title: String, _ duration: TimeInterval) {
            self.slug = slug
            self.title = title
            self.duration = duration
        }
    }

    private static let artistSpecs: [ArtistSpec] = [
        ArtistSpec(slug: "nova-atlas", name: "Nova Atlas", genre: "Dream Pop", releases: [
            ReleaseSpec(slug: "harbor-static", title: "Harbor Static", year: 2019, month: 4, seed: 0x5EA_1001,
                        colors: ["#1D3557", "#E76F51", "#F4A261"], songs: [
                SongSpec("salt-in-the-wires", "Salt in the Wires", 104), SongSpec("blue-hour-ferry", "Blue Hour Ferry", 96),
                SongSpec("northbound-glow", "Northbound Glow", 112), SongSpec("pier-seventeen", "Pier Seventeen", 88),
                SongSpec("weather-radio", "Weather Radio", 100), SongSpec("paper-moons", "Paper Moons", 92),
            ]),
            ReleaseSpec(slug: "lantern-season", title: "Lantern Season", kind: .ep, year: 2021, month: 10, seed: 0x5EA_1002,
                        colors: ["#2A9D8F", "#E9C46A", "#264653"], songs: [
                SongSpec("lantern-season-song", "Lantern Season", 98), SongSpec("small-fires", "Small Fires", 86),
                SongSpec("the-long-window", "The Long Window", 108), SongSpec("rooftop-choir", "Rooftop Choir", 94),
            ]),
            ReleaseSpec(slug: "glasswork", title: "Glasswork", year: 2023, month: 2, seed: 0x5EA_1003,
                        colors: ["#6D597A", "#E56B6F", "#EAAC8B"], songs: [
                SongSpec("glasswork-song", "Glasswork", 110), SongSpec("velvet-signal", "Velvet Signal", 96),
                SongSpec("overpass-bloom", "Overpass Bloom", 102), SongSpec("quiet-engines", "Quiet Engines", 90),
                SongSpec("halfway-bright", "Halfway Bright", 98), SongSpec("satellite-pier", "Satellite Pier", 106),
                SongSpec("all-the-small-lights", "All the Small Lights", 118),
            ]),
            ReleaseSpec(slug: "tidewater", title: "Tidewater", kind: .single, year: 2024, month: 8, seed: 0x5EA_1004,
                        colors: ["#0B6E4F", "#F7B267", "#F25C54"], songs: [SongSpec("tidewater-song", "Tidewater", 94)]),
            ReleaseSpec(slug: "low-tide-lights", title: "Low Tide Lights", year: 2025, month: 5, original: 0, songs: [
                SongSpec("undertow-parade", "Undertow Parade", 100), SongSpec("neon-gulls", "Neon Gulls", 88),
                SongSpec("moonwake", "Moonwake", 104), SongSpec("signal-fires", "Signal Fires", 96),
                SongSpec("driftwood-radio", "Driftwood Radio", 110),
            ]),
            ReleaseSpec(slug: "afterlight-sessions", title: "Afterlight Sessions", kind: .ep, year: 2026, month: 3, seed: 0x5EA_1005,
                        colors: ["#3D348B", "#F7B801", "#F18701"], songs: [
                SongSpec("afterlight", "Afterlight", 92), SongSpec("seafoam-static", "Seafoam Static", 100),
                SongSpec("little-harbor-hymn", "Little Harbor Hymn", 86),
            ]),
        ]),
        ArtistSpec(slug: "the-quiet-ferns", name: "The Quiet Ferns", genre: "Indie Folk", releases: [
            ReleaseSpec(slug: "greenhouse-radio", title: "Greenhouse Radio", year: 2020, month: 9, seed: 0x5EA_2001,
                        colors: ["#386641", "#F2E8CF", "#BC4749"], songs: [
                SongSpec("greenhouse-radio-song", "Greenhouse Radio", 102), SongSpec("mossy-telephones", "Mossy Telephones", 94),
                SongSpec("cardinal-static", "Cardinal Static", 98), SongSpec("fern-and-ferry", "Fern & Ferry", 90),
                SongSpec("window-garden", "Window Garden", 106),
            ]),
            ReleaseSpec(slug: "moss-letters", title: "Moss Letters", kind: .ep, year: 2022, month: 3, seed: 0x5EA_2002,
                        colors: ["#606C38", "#DDA15E", "#283618"], songs: [
                SongSpec("moss-letters-song", "Moss Letters", 96), SongSpec("rain-check-waltz", "Rain Check Waltz", 88),
                SongSpec("kettle-song", "Kettle Song", 92),
            ]),
            ReleaseSpec(slug: "signal-and-bloom", title: "Signal & Bloom", year: 2024, month: 4, original: 1, songs: [
                SongSpec("bloom-frequency", "Bloom Frequency", 100), SongSpec("postcard-static", "Postcard Static", 94),
                SongSpec("antenna-garden", "Antenna Garden", 108), SongSpec("soft-reception", "Soft Reception", 90),
            ]),
            ReleaseSpec(slug: "pollen-drift", title: "Pollen Drift", kind: .single, year: 2025, month: 7, seed: 0x5EA_2003,
                        colors: ["#FFB4A2", "#6D6875", "#E5989B"], songs: [SongSpec("pollen-drift-song", "Pollen Drift", 96)]),
        ]),
        ArtistSpec(slug: "lumen-vale", name: "Lumen Vale", genre: "Synthwave", releases: [
            ReleaseSpec(slug: "copper-hours", title: "Copper Hours", year: 2020, month: 11, seed: 0x5EA_3001,
                        colors: ["#9D0208", "#FFBA08", "#370617"], songs: [
                SongSpec("copper-hours-song", "Copper Hours", 104), SongSpec("mile-marker-ninety", "Mile Marker Ninety", 98),
                SongSpec("sodium-lights", "Sodium Lights", 110), SongSpec("night-market-drive", "Night Market Drive", 96),
                SongSpec("tachometer-heart", "Tachometer Heart", 92),
            ]),
            ReleaseSpec(slug: "night-shift-radio", title: "Night Shift Radio", year: 2023, month: 9, original: 2, songs: [
                SongSpec("graveyard-shift-disco", "Graveyard Shift Disco", 102), SongSpec("overtime-glow", "Overtime Glow", 94),
                SongSpec("dashboard-saints", "Dashboard Saints", 100), SongSpec("static-sunrise", "Static Sunrise", 108),
            ]),
            ReleaseSpec(slug: "afterglow-exit", title: "Afterglow Exit", year: 2025, month: 1, seed: 0x5EA_3002,
                        colors: ["#7209B7", "#F72585", "#4CC9F0"], songs: [
                SongSpec("afterglow-exit-song", "Afterglow Exit", 106), SongSpec("neon-toll-booth", "Neon Toll Booth", 96),
                SongSpec("rearview-comets", "Rearview Comets", 100), SongSpec("midnight-detour", "Midnight Detour", 112),
                SongSpec("chrome-lullaby", "Chrome Lullaby", 90),
            ]),
            ReleaseSpec(slug: "rush-hour-ghosts", title: "Rush Hour Ghosts", kind: .ep, year: 2026, month: 2, seed: 0x5EA_3003,
                        colors: ["#0F4C5C", "#E36414", "#FB8B24"], songs: [
                SongSpec("rush-hour-ghosts-song", "Rush Hour Ghosts", 98), SongSpec("interchange", "Interchange", 92),
                SongSpec("last-exit-glow", "Last Exit Glow", 104),
            ]),
        ]),
        ArtistSpec(slug: "kiyi-sinyali", name: "Kıyı Sinyali", genre: "Pop", turkish: true, releases: [
            ReleaseSpec(slug: "mavi-saat", title: "Mavi Saat", year: 2023, month: 5, seed: 0x5EA_4001,
                        colors: ["#023E8A", "#90E0EF", "#FF8500"], songs: [
                SongSpec("mavi-saat-sarki", "Mavi Saat", 100), SongSpec("vapur-dudugu", "Vapur Düdüğü", 94),
                SongSpec("rihtimda-dans", "Rıhtımda Dans", 106), SongSpec("ay-isigi-hatti", "Ay Işığı Hattı", 98),
                SongSpec("martilar-ve-biz", "Martılar ve Biz", 92),
            ]),
            ReleaseSpec(slug: "liman-isiklari", title: "Liman Işıkları", kind: .ep, year: 2025, month: 6, seed: 0x5EA_4002,
                        colors: ["#C9184A", "#FFCCD5", "#590D22"], songs: [
                SongSpec("liman-isiklari-sarki", "Liman Işıkları", 96), SongSpec("dalgakiran", "Dalgakıran", 90),
                SongSpec("gece-feribotu", "Gece Feribotu", 102),
            ]),
            ReleaseSpec(slug: "gece-yarisi-frekansi", title: "Gece Yarısı Frekansı", year: 2026, month: 4, original: 3, songs: [
                SongSpec("frekans", "Frekans", 98), SongSpec("sokak-lambalari", "Sokak Lambaları", 104),
                SongSpec("kumsalda-radyo", "Kumsalda Radyo", 92), SongSpec("sabaha-karsi", "Sabaha Karşı", 108),
            ]),
        ]),
        ArtistSpec(slug: "orbit-and-ivy", name: "Orbit & Ivy", genre: "Electronic", releases: [
            ReleaseSpec(slug: "slow-comet", title: "Slow Comet", year: 2022, month: 8, seed: 0x5EA_5001,
                        colors: ["#22223B", "#9A8C98", "#F2E9E4"], songs: [
                SongSpec("slow-comet-song", "Slow Comet", 108), SongSpec("ivy-on-the-antenna", "Ivy on the Antenna", 96),
                SongSpec("gravity-letters", "Gravity Letters", 100), SongSpec("low-orbit-lullaby", "Low Orbit Lullaby", 94),
            ]),
            ReleaseSpec(slug: "satellite-hearts", title: "Satellite Hearts", year: 2024, month: 10, seed: 0x5EA_5002,
                        colors: ["#FF006E", "#8338EC", "#3A86FF"], songs: [
                SongSpec("satellite-hearts-song", "Satellite Hearts", 102), SongSpec("moon-garden-club", "Moon Garden Club", 98),
                SongSpec("orbitals", "Orbitals", 110), SongSpec("zero-g-waltz", "Zero-G Waltz", 92),
                SongSpec("starlit-static", "Starlit Static", 104),
            ]),
        ]),
        ArtistSpec(slug: "marlow-and-pine", name: "Marlow & Pine", genre: "Acoustic", releases: [
            ReleaseSpec(slug: "field-notes", title: "Field Notes", year: 2021, month: 4, seed: 0x5EA_6001,
                        colors: ["#BC6C25", "#FEFAE0", "#283618"], songs: [
                SongSpec("field-notes-song", "Field Notes", 96), SongSpec("porch-light-theory", "Porch Light Theory", 100),
                SongSpec("two-rivers-over", "Two Rivers Over", 92), SongSpec("barn-owl-radio", "Barn Owl Radio", 104),
            ]),
            ReleaseSpec(slug: "paper-lanterns", title: "Paper Lanterns", year: 2025, month: 9, seed: 0x5EA_6002,
                        colors: ["#F4A261", "#2A9D8F", "#E9C46A"], songs: [
                SongSpec("paper-lanterns-song", "Paper Lanterns", 98), SongSpec("cedar-smoke", "Cedar Smoke", 94),
                SongSpec("wildflower-static", "Wildflower Static", 106), SongSpec("kitchen-table-hymn", "Kitchen Table Hymn", 90),
                SongSpec("evening-train", "Evening Train", 102),
            ]),
        ]),
    ]

    private struct PlaylistSpec {
        var slug: String
        var name: String
        var songs: [String]
    }

    private static let playlistSpecs: [PlaylistSpec] = [
        PlaylistSpec(slug: "late-night-drive", name: "Late Night Drive", songs: [
            "copper-moon-drive", "sodium-lights", "glass-harbor", "neon-toll-booth", "orbitals", "midnight-detour",
            "graveyard-shift-disco", "signal-fires", "last-exit-glow", "satellite-hearts-song",
        ]),
        PlaylistSpec(slug: "sunday-slow", name: "Sunday Slow", songs: [
            "paper-satellites", "kettle-song", "field-notes-song", "cedar-smoke", "window-garden", "little-harbor-hymn",
            "kitchen-table-hymn", "rain-check-waltz",
        ]),
        PlaylistSpec(slug: "sahil-sarkilari", name: "Sahil Şarkıları", songs: [
            "sahilde-neon", "mavi-saat-sarki", "liman-isiklari-sarki", "rihtimda-dans", "gece-feribotu", "kumsalda-radyo",
            "tidewater-song", "blue-hour-ferry",
        ]),
        PlaylistSpec(slug: "deep-focus", name: "Deep Focus", songs: [
            "slow-comet-song", "quiet-engines", "gravity-letters", "the-long-window", "soft-reception", "low-orbit-lullaby",
            "velvet-signal", "starlit-static",
        ]),
    ]

    private static func date(year: Int, month: Int) -> Date? {
        CatalogDates.utcCalendar.date(from: DateComponents(year: year, month: month, day: 1, hour: 12))
    }

    /// Invented lines on a two-bar grid (4 s at 120 BPM): a verse, a
    /// break, a chorus, then instrumental to the end.
    private static func lyrics(seed: UInt64, duration: TimeInterval, turkish: Bool) -> SyncedLyrics {
        var random = SplitMix64(seed: seed)
        let pool = turkish ? turkishLines : englishLines
        var picked: [String] = []
        var available = Array(pool.indices)
        for _ in 0..<min(12, pool.count) {
            let index = Int(random.next() % UInt64(available.count))
            picked.append(pool[available.remove(at: index)])
        }
        let starts: [TimeInterval] = [4, 8, 12, 16, 20, 24, 28, 32, 48, 52, 56, 60]
        let lines = zip(starts, picked).compactMap { start, text -> LyricLine? in
            guard start + DemoCatalog.lineLength <= duration else { return nil }
            return LyricLine(start: start, end: start + DemoCatalog.lineLength, text: text)
        }
        return SyncedLyrics(lines: lines)
    }

    private static let englishLines = [
        "Every window hums a little louder",
        "We trace the city in the rain",
        "Hold the static like a secret",
        "Paper boats along the drain",
        "The radio remembers summer",
        "Count the headlights one by one",
        "I left a light on in the hallway",
        "We were waiting for the sun",
        "Turn the night into a chorus",
        "Every signal finds its way",
        "Slow dance on an empty platform",
        "Keep the colors where they stay",
        "Fold the evening into pockets",
        "Somebody's singing through the wall",
        "Neon letters on the water",
        "Answer when the comets call",
        "The kettle sings before the morning",
        "We wrote our names in window frost",
        "Little engines in the distance",
        "Nothing found and nothing lost",
        "Follow the hum along the river",
        "Leave the porch light burning low",
        "Every map is drawn in pencil",
        "Every road is ours to know",
    ]

    private static let turkishLines = [
        "Rıhtımda ışıklar yanıyor",
        "Martılar şarkı söylüyor",
        "Vapur sabaha yetişir",
        "Dalgalar adımı biliyor",
        "Gece mavi bir saat gibi",
        "Rüzgâr kapıyı çalıyor",
        "Şehir uykusundan uyanır",
        "Kalbim ritmi tutuyor",
        "Feneri yak, bekliyorum",
        "Kumsalda radyo çalıyor",
        "Yıldızlar suya dökülür",
        "Bu şarkı bizimle kalsın",
        "Sokak lambaları göz kırpar",
        "Liman sessizce dinliyor",
    ]
}

/// The demo library as a searchable catalog (`--demo`). A small, steady
/// latency makes the player's loading states visible, as with a real
/// catalog.
public final class DemoMusicCatalog: MusicCatalog {
    public let library: DemoLibrary
    private let latency: TimeInterval

    public init(library: DemoLibrary = .standard, latency: TimeInterval = 0) {
        self.library = library
        self.latency = max(0, latency)
    }

    public func search(_ term: String, limit: Int) async throws -> CatalogSearchResults {
        await wait()
        let words = TrackMatching.normalized(term).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return CatalogSearchResults() }
        func score(_ fields: [String]) -> Int? {
            let text = fields.map(TrackMatching.normalized).joined(separator: " ")
            guard words.allSatisfy({ text.contains($0) }) else { return nil }
            let first = TrackMatching.normalized(fields[0])
            return first.hasPrefix(words.joined(separator: " ")) ? 0 : (words.allSatisfy { first.contains($0) } ? 1 : 2)
        }
        func ranked<T>(_ items: [T], _ fields: (T) -> [String]) -> [T] {
            items.enumerated().compactMap { offset, item in score(fields(item)).map { ($0, offset, item) } }
                .sorted { ($0.0, $0.1) < ($1.0, $1.1) }
                .map(\.2)
        }
        return CatalogSearchResults(
            songs: Array(ranked(library.catalogSongs) { [$0.title, $0.artistName, $0.albumTitle] }.prefix(limit)),
            albums: Array(ranked(library.albums) { [$0.title, $0.artistName] }.prefix(10)),
            artists: Array(ranked(library.artists) { [$0.name, $0.genre ?? ""] }.prefix(6))
        )
    }

    public func artist(for track: Track) async throws -> CatalogArtistMatch? {
        await wait()
        guard let artist = library.artist(named: track.artist) else { return nil }
        let album = TrackMatching.normalized(track.album)
        let albumID = library.albums(ofArtist: artist.id).first { TrackMatching.normalized($0.title) == album }?.id
        let song = albumID.flatMap { id in library.songs(ofAlbum: id).first { $0.id == track.id || TrackMatching.normalized($0.title) == TrackMatching.normalized(track.title) } }
        return CatalogArtistMatch(artist: artist, albumID: albumID, song: song)
    }

    public func albums(of artist: CatalogArtist) async throws -> [CatalogAlbum] {
        await wait()
        return ITunesCatalog.arrangeAlbums(library.albums(ofArtist: artist.id))
    }

    public func songs(of album: CatalogAlbum) async throws -> [CatalogSong] {
        await wait()
        return library.songs(ofAlbum: album.id)
    }

    public func topSongs(of artist: CatalogArtist, limit: Int) async throws -> [CatalogSong] {
        await wait()
        let albums = library.albums(ofArtist: artist.id).reversed().map { library.songs(ofAlbum: $0.id) }
        var result: [CatalogSong] = []
        var depth = 0
        while result.count < limit, albums.contains(where: { depth < $0.count }) {
            for songs in albums where depth < songs.count && result.count < limit {
                result.append(songs[depth])
            }
            depth += 1
        }
        return result
    }

    public func playlists() -> [CatalogPlaylist] {
        library.playlists
    }

    public func songs(ofPlaylist id: String) -> [CatalogSong] {
        library.songs(ofPlaylist: id)
    }

    private func wait() async {
        guard latency > 0 else { return }
        try? await Task.sleep(for: .seconds(latency))
    }
}
