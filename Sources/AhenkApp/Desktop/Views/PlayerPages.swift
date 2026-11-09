import AhenkKit
import AppKit
import SwiftUI

/// The glass page above the search field: search results, an album or an
/// artist, with a back button when there is somewhere to go back to.
struct PageArea: View {
    let model: DesktopPlayerModel

    var body: some View {
        let theme = model.theme
        VStack(spacing: 0) {
            header
            Group {
                switch model.pageContent {
                case .page(.album(let album)):
                    AlbumPageView(model: model, album: album)
                case .page(.artist(let artist)):
                    ArtistPageView(model: model, artist: artist)
                case .search:
                    SearchResultsView(model: model)
                case .queue:
                    QueueList(model: model, showsContext: true)
                case nil:
                    Color.clear
                }
            }
            .id(model.pageContent.map(Self.identity))
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: PlayerLayout.pageHeight)
        .widgetGlass(RoundedRectangle(cornerRadius: 26, style: .continuous), tint: theme.glass)
        .animation(.smooth(duration: 0.22), value: model.pageContent.map(Self.identity))
    }

    private static func identity(_ content: PageContent) -> String {
        switch content {
        case .page(let page): page.id
        case .search: "search"
        case .queue: "queue"
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            if model.canGoBack {
                WidgetIconButton(symbol: "chevron.left", pointSize: 13, side: 28, help: "Back".l10n) {
                    model.back()
                }
                .transition(.opacity)
            }
            Text(headerTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
            Spacer(minLength: 8)
            WidgetIconButton(symbol: "xmark", pointSize: 11.5, side: 28, help: "Close".l10n) {
                model.closePages()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .movesWidget()
    }

    private var headerTitle: String {
        switch model.pageContent {
        case .page(.album): "Album".l10n
        case .page(.artist): "Artist".l10n
        case .search: L10n.format("Results for \u{201C}%@\u{201D}", model.query.trimmingCharacters(in: .whitespacesAndNewlines))
        case .queue: "Queue".l10n
        case nil: ""
        }
    }
}

// MARK: - Search results

struct SearchResultsView: View {
    let model: DesktopPlayerModel

    var body: some View {
        switch model.search {
        case .idle, .loading:
            WidgetMessage(text: "Searching…".l10n, isLoading: true)
        case .failed(let message):
            WidgetMessage(symbol: "wifi.exclamationmark", text: message, actionTitle: "Try Again".l10n) {
                model.retrySearch()
            }
        case .loaded(let results) where results.isEmpty:
            WidgetMessage(
                symbol: "magnifyingglass",
                text: L10n.format("Nothing found for \u{201C}%@\u{201D}. Check the spelling or try fewer words.", model.query.trimmingCharacters(in: .whitespaces))
            )
        case .loaded(let results):
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    if !results.artists.isEmpty {
                        ArtistChips(model: model, artists: results.artists)
                    }
                    if !results.songs.isEmpty {
                        HStack {
                            WidgetSectionTitle(title: "Songs".l10n)
                            if results.songs.count > songLimit {
                                Button(showsAllSongs ? "Show Fewer".l10n : "Show All".l10n) {
                                    withAnimation(.smooth(duration: 0.22)) { showsAllSongs.toggle() }
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(model.theme.accent)
                            }
                        }
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 2) {
                            ForEach(showsAllSongs ? results.songs : Array(results.songs.prefix(songLimit))) { song in
                                SearchSongRow(model: model, song: song)
                            }
                        }
                    }
                    if !results.albums.isEmpty {
                        WidgetSectionTitle(title: "Albums".l10n)
                        AlbumShelf(model: model, albums: results.albums)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 2)
                .padding(.bottom, 18)
            }
            .scrollIndicators(.never)
            .fadesScrollEdges()
            .onChange(of: model.query) { showsAllSongs = false }
        }
    }

    @State private var showsAllSongs = false

    /// Two rows' worth of songs in the small player, four in the large.
    private var songLimit: Int { model.size == .large ? 8 : 4 }

    private var columns: [GridItem] {
        let count = model.size == .large ? 2 : 1
        return Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .leading), count: count)
    }
}

/// A song found by search: plays alone when clicked; right-click queues it.
private struct SearchSongRow: View {
    let model: DesktopPlayerModel
    let song: CatalogSong

    var body: some View {
        Button {
            model.playFromSearch(song)
        } label: {
            HStack(spacing: 10) {
                CoverArt(song: song, side: 36, cornerRadius: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(song.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text([song.artistName, song.albumTitle].filter { !$0.isEmpty }.joined(separator: " \u{00B7} "))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if model.isPlaying(song) {
                    EqualizerBars(isPlaying: model.isPlaying, color: model.theme.accent)
                        .frame(width: 14, height: 12)
                } else if song.duration > 0 {
                    Text(DurationText.string(song.duration))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .rowHighlight(isPlaying: model.isPlaying(song), accent: model.theme.accent, cornerRadius: 10)
        .songMenu(model: model, songs: [song], album: song.albumID.flatMap { id in
            model.search.value?.albums.first { $0.id == id }
        })
        .help(L10n.format("Play \u{201C}%@\u{201D}", song.title))
        .accessibilityLabel(song.artistName.isEmpty ? song.title : "\(song.title), \(song.artistName)")
    }
}

/// Albums in a row of covers with their title and year.
struct AlbumShelf: View {
    let model: DesktopPlayerModel
    let albums: [CatalogAlbum]
    var side: CGFloat = 104

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(albums) { album in
                    Button {
                        model.open(.album(album))
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            CoverArt(artwork: album.artwork, side: side, cornerRadius: 10)
                                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                            Text(album.title)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(album.yearAndKind)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.white.opacity(0.55))
                                .lineLimit(1)
                        }
                        .frame(width: side)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Play".l10n, systemImage: "play.fill") { model.playAlbum(album) }
                        Button("Play Next".l10n, systemImage: "text.line.first.and.arrowtriangle.forward") { model.playAlbum(album, mode: .playNext) }
                        Button("Add to Queue".l10n, systemImage: "text.append") { model.playAlbum(album, mode: .addToQueue) }
                    }
                    .accessibilityLabel("\(album.title), \(album.yearAndKind)")
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.never)
    }
}

private struct ArtistChips: View {
    let model: DesktopPlayerModel
    let artists: [CatalogArtist]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(artists) { artist in
                    Button {
                        model.open(.artist(artist))
                    } label: {
                        HStack(spacing: 8) {
                            ArtistMonogram(name: artist.name, side: 26, palette: model.theme.palette)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(artist.name)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                if let genre = artist.genre, !genre.isEmpty {
                                    Text(genre)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.white.opacity(0.55))
                                        .lineLimit(1)
                                }
                            }
                        }
                        .padding(.leading, 5)
                        .padding(.trailing, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(.white.opacity(0.1)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(artist.name)
                }
            }
        }
        .scrollIndicators(.never)
    }
}

/// An artist's initials on a gradient (the public catalog has no artist
/// pictures).
struct ArtistMonogram: View {
    let name: String
    let side: CGFloat
    let palette: Palette

    var body: some View {
        let seed = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        let colors = palette.vivid
        let first = Color(colors[seed % colors.count])
        let second = Color(colors[(seed / 7 + 1) % colors.count])
        Circle()
            .fill(LinearGradient(colors: [first, second.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                Text(initials)
                    .font(.system(size: side * 0.38, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            }
            .frame(width: side, height: side)
            .accessibilityHidden(true)
    }

    private var initials: String {
        let words = name.split(whereSeparator: { $0.isWhitespace || $0 == "&" }).prefix(2)
        return words.compactMap { $0.first.map { String($0).uppercased() } }.joined()
    }
}

// MARK: - Album

struct AlbumPageView: View {
    let model: DesktopPlayerModel
    let album: CatalogAlbum

    var body: some View {
        let theme = model.theme
        let songs = model.albumSongs[album.id]
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                CoverArt(artwork: album.artwork, side: model.size == .large ? 176 : 150, cornerRadius: 12)
                    .shadow(color: .black.opacity(0.4), radius: 10, y: 5)
                VStack(alignment: .leading, spacing: 3) {
                    Text(album.title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Button {
                        if let id = album.artistID {
                            model.open(.artist(CatalogArtist(id: id, name: album.artistName)))
                        }
                    } label: {
                        Text(album.artistName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(theme.accent)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .disabled(album.artistID == nil)
                    Text(details(songs?.value))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    CapsuleButton(title: "Play".l10n, symbol: "play.fill", filled: true, accent: theme.accent) {
                        model.playAlbum(album)
                    }
                    WidgetIconButton(symbol: "shuffle", pointSize: 12.5, side: 30, help: "Shuffle".l10n) {
                        model.playAlbum(album, mode: .shuffle)
                    }
                    .background(Circle().fill(.white.opacity(0.12)))
                    Menu {
                        Button("Play Next".l10n, systemImage: "text.line.first.and.arrowtriangle.forward") { model.playAlbum(album, mode: .playNext) }
                        Button("Add to Queue".l10n, systemImage: "text.append") { model.playAlbum(album, mode: .addToQueue) }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(.white.opacity(0.12)))
                            .contentShape(Circle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More".l10n)
                }
            }
            .frame(width: model.size == .large ? 176 : 150, alignment: .leading)

            songList(songs)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
    }

    private func details(_ songs: [CatalogSong]?) -> String {
        let count = songs?.count ?? album.trackCount
        var parts = [album.yearAndKind]
        if count > 0 { parts.append(SongCount.text(count)) }
        return parts.joined(separator: " \u{00B7} ")
    }

    @ViewBuilder
    private func songList(_ state: Loadable<[CatalogSong]>?) -> some View {
        switch state {
        case .loaded(let songs) where songs.isEmpty:
            WidgetMessage(symbol: "music.note", text: "This album has no songs to play.".l10n)
        case .loaded(let songs):
            ScrollView(.vertical) {
                LazyVStack(spacing: 1) {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                        AlbumSongRow(model: model, song: song, number: song.trackNumber ?? index + 1) {
                            model.play(songs, at: index, context: .album(id: album.id, title: album.title))
                        }
                        .songMenu(model: model, songs: [song])
                    }
                }
                .padding(.top, 2)
                .padding(.bottom, 18)
            }
            .scrollIndicators(.never)
            .fadesScrollEdges()
        case .failed(let message):
            WidgetMessage(symbol: "wifi.exclamationmark", text: message, actionTitle: "Try Again".l10n) {
                model.retryAlbumSongs(album)
            }
        case .idle, .loading, nil:
            WidgetMessage(text: "Loading the songs…".l10n, isLoading: true)
        }
    }
}

/// A numbered song of an album; bars instead of the number while it plays.
private struct AlbumSongRow: View {
    let model: DesktopPlayerModel
    let song: CatalogSong
    let number: Int
    let action: () -> Void

    var body: some View {
        let playing = model.isPlaying(song)
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    if playing {
                        EqualizerBars(isPlaying: model.isPlaying, color: model.theme.accent)
                            .frame(width: 14, height: 12)
                    } else {
                        Text(verbatim: String(number))
                            .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
                .frame(width: 22)
                Text(song.title)
                    .font(.system(size: 12.5, weight: playing ? .semibold : .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if song.isExplicit {
                    Image(systemName: "e.square.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                        .accessibilityLabel("Explicit".l10n)
                }
                Spacer(minLength: 6)
                if song.duration > 0 {
                    Text(DurationText.string(song.duration))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .rowHighlight(isPlaying: playing, accent: model.theme.accent, cornerRadius: 9)
        .accessibilityLabel(song.title)
    }
}

// MARK: - Artist

struct ArtistPageView: View {
    let model: DesktopPlayerModel
    let artist: CatalogArtist

    var body: some View {
        let theme = model.theme
        let content = model.artistContent[artist.id]
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                ArtistMonogram(name: artist.name, side: model.size == .large ? 120 : 100, palette: theme.palette)
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 5)
                VStack(alignment: .leading, spacing: 3) {
                    Text(artist.name)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if let genre = artist.genre, !genre.isEmpty {
                        Text(genre)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                if let top = content?.value?.topSongs, !top.isEmpty {
                    CapsuleButton(title: "Play".l10n, symbol: "play.fill", filled: true, accent: theme.accent) {
                        model.play(top, at: 0, context: .artist(id: artist.id, name: artist.name))
                    }
                }
            }
            .frame(width: model.size == .large ? 150 : 120, alignment: .leading)

            Group {
                switch content {
                case .loaded(let page):
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 14) {
                            if !page.topSongs.isEmpty {
                                WidgetSectionTitle(title: "Top Songs".l10n)
                                VStack(spacing: 1) {
                                    ForEach(Array(page.topSongs.prefix(4).enumerated()), id: \.element.id) { index, song in
                                        SongRow(
                                            song: song, isPlaying: model.isPlaying(song), isAnimating: model.isPlaying,
                                            accent: theme.accent, coverSide: 32, showsDuration: true
                                        ) {
                                            model.play(page.topSongs, at: index, context: .artist(id: artist.id, name: artist.name))
                                        }
                                        .songMenu(model: model, songs: [song])
                                    }
                                }
                            }
                            if !page.albums.isEmpty {
                                WidgetSectionTitle(title: "Albums, EPs and Singles".l10n)
                                AlbumShelf(model: model, albums: page.albums.reversed(), side: 84)
                            }
                            if page.topSongs.isEmpty && page.albums.isEmpty {
                                WidgetMessage(symbol: "music.mic", text: "The catalog has nothing by this artist yet.".l10n)
                            }
                        }
                        .padding(.bottom, 18)
                    }
                    .scrollIndicators(.never)
                    .fadesScrollEdges()
                case .failed(let message):
                    WidgetMessage(symbol: "wifi.exclamationmark", text: message, actionTitle: "Try Again".l10n) {
                        model.retryArtist(artist)
                    }
                case .idle, .loading, nil:
                    WidgetMessage(text: "Loading the artist…".l10n, isLoading: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
    }
}
