import AhenkKit
import SwiftUI

/// Continue Playing: the songs played most recently (or a playlist chosen
/// from the title's menu), the playing one highlighted. Clicking a song
/// plays the list from there; the round button plays the whole list or
/// pauses it.
struct ContinuePlayingWidget: View {
    let model: DesktopPlayerModel

    var body: some View {
        let theme = model.theme
        VStack(spacing: 0) {
            header(theme: theme)
            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(height: 0.5)
                .padding(.horizontal, 14)
            content(theme: theme)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetGlass(RoundedRectangle(cornerRadius: 26, style: .continuous), tint: theme.glass)
        .movesWidget()
        .environment(\.colorScheme, .dark)
        .environment(\.coverImages, model.images)
        .padding(Self.margin)
    }

    /// Clear room around the glass for its shadow.
    static let margin: CGFloat = 14

    // MARK: Header

    private func header(theme: PlayerTheme) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Menu {
                listMenu
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(title)
                            .font(.system(size: 17, weight: .bold))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Text(subtitle)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose a playlist".l10n)

            Spacer(minLength: 4)

            Button {
                model.toggleList()
            } label: {
                Image(systemName: model.isListPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.black.opacity(0.82))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(theme.accent))
                    .shadow(color: theme.accent.opacity(0.4), radius: 6, y: 1)
                    .contentShape(Circle())
            }
            .buttonStyle(PressableStyle())
            .disabled(model.listSongs.isEmpty)
            .opacity(model.listSongs.isEmpty ? 0.4 : 1)
            .help(model.isListPlaying ? "Pause the list".l10n : "Play the whole list".l10n)
            .accessibilityLabel(model.isListPlaying ? "Pause the list".l10n : "Play the whole list".l10n)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var title: String {
        switch model.listSelection {
        case .continuePlaying: "Continue Playing".l10n
        case .playlist(let playlist): playlist.name
        }
    }

    private var subtitle: String {
        switch model.listSelection {
        case .continuePlaying:
            return "Recently played".l10n
        case .playlist(let playlist):
            let count = model.playlistSongs.value?.count ?? playlist.songCount ?? 0
            return SongCount.text(count)
        }
    }

    @ViewBuilder
    private var listMenu: some View {
        Button {
            model.listSelection = .continuePlaying
        } label: {
            if model.listSelection == .continuePlaying {
                Label("Continue Playing".l10n, systemImage: "checkmark")
            } else {
                Text("Continue Playing".l10n)
            }
        }
        Divider()
        Section("Playlists".l10n) {
            switch model.playlists {
            case .playlists(let lists) where !lists.isEmpty:
                ForEach(lists) { playlist in
                    Button {
                        model.listSelection = .playlist(playlist)
                    } label: {
                        if model.listSelection == .playlist(playlist) {
                            Label(playlist.name, systemImage: "checkmark")
                        } else {
                            Text(playlist.name)
                        }
                    }
                }
            case .playlists:
                Text("No playlists".l10n)
            case .unavailable(let reason):
                Text(reason)
            case nil:
                Text("Loading…".l10n)
            }
        }
        Divider()
        Button("Refresh Playlists".l10n) {
            model.refreshPlaylists()
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func content(theme: PlayerTheme) -> some View {
        let songs = model.listSongs
        if case .playlist = model.listSelection, model.playlistSongs.isLoading {
            WidgetMessage(text: "Loading the playlist…".l10n, isLoading: true)
        } else if songs.isEmpty {
            WidgetMessage(symbol: "music.note.list", text: emptyText)
        } else {
            ScrollView(.vertical) {
                LazyVStack(spacing: 2) {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                        SongRow(
                            song: song, isPlaying: model.isPlaying(song), isAnimating: model.isPlaying, accent: theme.accent
                        ) {
                            model.play(songs, at: index, context: model.listContext)
                        }
                        .songMenu(model: model, songs: [song], removable: model.listSelection == .continuePlaying)
                        .help(L10n.format("Play from \u{201C}%@\u{201D}", song.title))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 20)
            }
            .scrollIndicators(.never)
            .fadesScrollEdges()
        }
    }

    private var emptyText: String {
        switch model.listSelection {
        case .continuePlaying: "Songs you play appear here.".l10n
        case .playlist: "This playlist is empty.".l10n
        }
    }
}

/// One song in a list: cover, title, artist; bars while it plays.
struct SongRow: View {
    let song: CatalogSong
    let isPlaying: Bool
    let isAnimating: Bool
    let accent: Color
    var coverSide: CGFloat = 38
    var showsDuration = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                CoverArt(song: song, side: coverSide, cornerRadius: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(song.artistName)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if isPlaying {
                    EqualizerBars(isPlaying: isAnimating, color: accent)
                        .frame(width: 14, height: 12)
                        .padding(.trailing, 4)
                } else if showsDuration, song.duration > 0 {
                    Text(DurationText.string(song.duration))
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .rowHighlight(isPlaying: isPlaying, accent: accent)
        .accessibilityLabel(song.artistName.isEmpty ? song.title : "\(song.title), \(song.artistName)")
    }
}

/// "1 song", "12 songs" in the UI language.
@MainActor
enum SongCount {
    static func text(_ count: Int) -> String {
        count == 1 ? "1 song".l10n : L10n.format("%d songs", count)
    }
}

extension View {
    /// Right-click actions for songs: play next, add to queue, the album
    /// (when known) and, in Continue Playing, remove.
    func songMenu(model: DesktopPlayerModel, songs: [CatalogSong], album: CatalogAlbum? = nil, removable: Bool = false) -> some View {
        contextMenu {
            Button("Play Next".l10n, systemImage: "text.line.first.and.arrowtriangle.forward") {
                model.playNext(songs)
            }
            Button("Add to Queue".l10n, systemImage: "text.append") {
                model.addToQueue(songs)
            }
            if let album {
                Divider()
                Button("Go to Album".l10n, systemImage: "square.stack") {
                    model.open(.album(album))
                }
            }
            if removable, let song = songs.first, let origin = song.origin {
                Divider()
                Button("Remove from Continue Playing".l10n, systemImage: "minus.circle") {
                    model.services.recentlyPlayed.remove(id: "\(origin.source.rawValue):\(origin.id)")
                }
            }
        }
    }
}
