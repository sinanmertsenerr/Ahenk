import AhenkKit
import AppKit
import SwiftUI

/// The player bar, left to right: where picks play, shuffle, previous,
/// play/pause, next, repeat, the song (cover, title, "artist — album", its
/// position), more, lyrics, queue, like and volume.
struct PlayerBar: View {
    let model: DesktopPlayerModel

    var body: some View {
        let theme = model.theme
        HStack(spacing: 4) {
            SourcePicker(model: model)
                .padding(.trailing, 4)
            TransportControls(model: model, accent: theme.accent)
            NowPlayingSummary(model: model)
                .padding(.horizontal, 10)
            BarActions(model: model, accent: theme.accent)
        }
        .padding(.leading, 12)
        .padding(.trailing, 12)
        .frame(height: PlayerLayout.barHeight)
        .widgetGlass(Capsule(), tint: theme.glass)
        .movesWidget()
    }
}

// MARK: - Source picker

/// A round badge in the source's colour; its menu picks where songs from
/// search, albums and lists play.
struct SourcePicker: View {
    let model: DesktopPlayerModel

    var body: some View {
        let current = model.listeningSource
        Menu {
            Section("Play Songs In".l10n) {
                if !model.router.isDemo {
                    Button {
                        model.choose(nil)
                    } label: {
                        checked("Automatic".l10n, model.settings.player.listeningSource == nil)
                    }
                    .help("Follows the source that plays.".l10n)
                }
                ForEach(model.sourceOptions) { source in
                    let reason = model.unavailableReason(for: source)
                    Button {
                        model.choose(source)
                    } label: {
                        let title = reason.map { "\(source.title) (\($0))" } ?? source.title
                        checked(title, model.settings.player.listeningSource == source || (model.router.isDemo && source == .demo))
                    }
                    .disabled(reason != nil)
                }
            }
        } label: {
            SourceBadge(source: current, demoColor: model.theme.accent)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.format("Songs you pick play here: %@", current.title))
        .accessibilityLabel(L10n.format("Songs you pick play here: %@", current.title))
    }

    @ViewBuilder
    private func checked(_ title: String, _ isOn: Bool) -> some View {
        if isOn {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }
}

struct SourceBadge: View {
    let source: MusicSource
    /// The demo has no colour of its own: it wears the song's.
    var demoColor: Color = .accentColor
    var side: CGFloat = 30

    var body: some View {
        let color = source == .demo ? demoColor : source.badgeColor
        Circle()
            .fill(color.gradient)
            .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
            .overlay {
                Image(systemName: source.badgeSymbol)
                    .font(.system(size: side * 0.43, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
            }
            .frame(width: side, height: side)
            .shadow(color: color.opacity(0.35), radius: 5, y: 1)
            .contentShape(Circle())
    }
}

// MARK: - Transport

private struct TransportControls: View {
    let model: DesktopPlayerModel
    let accent: Color

    var body: some View {
        let isPlaying = model.isPlaying
        let repeatMode = model.repeatMode
        HStack(spacing: 0) {
            WidgetIconButton(
                symbol: "shuffle", pointSize: 12.5, side: 30, isOn: model.isShuffled, accent: accent,
                isEnabled: model.canShuffle, help: model.isShuffled ? "Turn Shuffle Off".l10n : "Shuffle".l10n
            ) { model.toggleShuffle() }
            WidgetIconButton(symbol: "backward.fill", pointSize: 14, side: 32, isEnabled: model.canSkip, help: "Previous".l10n) {
                model.previous()
            }
            WidgetIconButton(
                symbol: isPlaying ? "pause.fill" : "play.fill", pointSize: 20, side: 40,
                isEnabled: model.canPlayPause || model.startingSong != nil, help: isPlaying ? "Pause".l10n : "Play".l10n
            ) { model.togglePlayPause() }
            WidgetIconButton(symbol: "forward.fill", pointSize: 14, side: 32, isEnabled: model.canSkip, help: "Next".l10n) {
                model.next()
            }
            WidgetIconButton(
                symbol: repeatMode == .one ? "repeat.1" : "repeat", pointSize: 12.5, side: 30, isOn: repeatMode != .off,
                accent: accent, isEnabled: model.canRepeat, help: Self.repeatHelp(repeatMode)
            ) { model.cycleRepeat() }
        }
    }

    @MainActor
    private static func repeatHelp(_ mode: RepeatMode) -> String {
        switch mode {
        case .off: "Repeat".l10n
        case .all: "Repeat One".l10n
        case .one: "Turn Repeat Off".l10n
        }
    }
}

// MARK: - The song

/// Cover, title, "artist — album" and the position line. While a song
/// starts, it shows that song with a soft pulse and a light running along
/// the line.
private struct NowPlayingSummary: View {
    let model: DesktopPlayerModel
    @State private var pulse = false

    var body: some View {
        let starting = model.startingSong
        let snapshot = model.snapshot
        let theme = model.theme
        HStack(spacing: 11) {
            cover(starting: starting)
                .overlay {
                    if starting != nil {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(theme.accent, lineWidth: 1.5)
                            .opacity(pulse ? 0.9 : 0.25)
                            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
                            .onAppear { pulse = true }
                            .onDisappear { pulse = false }
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(title(starting: starting, snapshot: snapshot))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle(starting: starting, snapshot: snapshot))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                ProgressLine(
                    snapshot: starting == nil ? snapshot : nil, isStarting: starting != nil, accent: theme.accent
                ) { seconds in
                    model.seek(to: seconds)
                }
                .frame(height: 10)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            if model.playingAlbum != nil { model.openPlayingAlbum() } else { model.openPlayingArtist() }
        }
        .contextMenu {
            Button("Go to Album".l10n, systemImage: "square.stack") { model.openPlayingAlbum() }
                .disabled(model.playingAlbum == nil)
            Button("Go to Artist".l10n, systemImage: "music.mic") { model.openPlayingArtist() }
                .disabled(model.artist == nil)
        }
        .animation(.smooth(duration: 0.25), value: starting?.id)
    }

    @ViewBuilder
    private func cover(starting: CatalogSong?) -> some View {
        if let starting {
            CoverArt(song: starting, side: 38, cornerRadius: 8)
        } else if let image = model.nowPlaying.artworkImage {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(0.12))
                .frame(width: 38, height: 38)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
        }
    }

    private func title(starting: CatalogSong?, snapshot: NowPlayingSnapshot?) -> String {
        if let starting { return starting.title }
        if let track = snapshot?.track, !track.title.isEmpty { return track.title }
        return "Not Playing".l10n
    }

    private func subtitle(starting: CatalogSong?, snapshot: NowPlayingSnapshot?) -> String {
        if starting != nil { return "Starting…".l10n }
        guard let track = snapshot?.track else { return "Pick a song to start.".l10n }
        return [track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " \u{2014} ")
    }
}

// MARK: - Actions

private struct BarActions: View {
    let model: DesktopPlayerModel
    let accent: Color

    var body: some View {
        HStack(spacing: 0) {
            if model.isVolumeOpen {
                VolumeSlider(value: model.volume ?? 0, accent: accent, isKnown: model.volume != nil) { value in
                    model.setVolume(value)
                }
                .frame(width: 104)
                .padding(.trailing, 6)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                MoreMenu(model: model)
                WidgetIconButton(
                    symbol: model.lyricsOn ? "quote.bubble.fill" : "quote.bubble", pointSize: 14, side: 32,
                    isOn: model.lyricsOn, accent: accent, help: model.lyricsOn ? "Hide Lyrics".l10n : "Show Lyrics".l10n
                ) { model.toggleLyrics() }
                WidgetIconButton(
                    symbol: "list.bullet", pointSize: 14, side: 32, isOn: model.isQueueOpen, accent: accent,
                    help: model.isQueueOpen ? "Hide the Queue".l10n : "Show the Queue".l10n
                ) { model.isQueueOpen.toggle() }
                WidgetIconButton(
                    symbol: model.isLiked ? "heart.fill" : "heart", pointSize: 14, side: 32, isOn: model.isLiked, accent: accent,
                    isEnabled: model.canLike, help: likeHelp
                ) { model.toggleLike() }
            }
            WidgetIconButton(
                symbol: volumeSymbol, pointSize: 14, side: 32, isOn: model.isVolumeOpen, accent: accent,
                isEnabled: model.hasVolume, help: model.hasVolume ? "Volume".l10n : "This player's volume cannot be changed from here.".l10n
            ) {
                withAnimation(.smooth(duration: 0.22)) { model.isVolumeOpen.toggle() }
            }
        }
    }

    private var likeHelp: String {
        guard model.canLike else { return "This source cannot keep favorites.".l10n }
        return model.isLiked ? "Remove from Favorites".l10n : "Add to Favorites".l10n
    }

    private var volumeSymbol: String {
        guard let volume = model.volume, model.isVolumeOpen else { return "speaker.wave.2.fill" }
        switch volume {
        case ..<0.01: return "speaker.slash.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
}

/// "…": go to the album or the artist, the player's size, layout and
/// settings.
private struct MoreMenu: View {
    let model: DesktopPlayerModel

    var body: some View {
        Menu {
            Button("Go to Album".l10n, systemImage: "square.stack") { model.openPlayingAlbum() }
                .disabled(model.playingAlbum == nil)
            Button("Go to Artist".l10n, systemImage: "music.mic") { model.openPlayingArtist() }
                .disabled(model.artist == nil)
            Divider()
            if model.size == .large {
                Button("Small Player".l10n, systemImage: "arrow.down.right.and.arrow.up.left") { model.setSize(.small) }
            } else {
                Button("Large Player".l10n, systemImage: "arrow.up.left.and.arrow.down.right") { model.setSize(.large) }
            }
            Button("Reset Layout".l10n, systemImage: "rectangle.3.group") { model.resetLayout() }
            Button("Add Sticker…".l10n, systemImage: "face.smiling") { model.addSticker() }
            Button("Sound Effects…".l10n, systemImage: "slider.vertical.3") { model.openSoundEffects() }
            Divider()
            Button("Desktop Player Settings…".l10n, systemImage: "gearshape") { model.openSettings() }
            Button("Hide the Desktop Player".l10n, systemImage: "eye.slash") { model.hidePlayer() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More".l10n)
        .accessibilityLabel("More".l10n)
    }
}

/// A thin slider for the source player's volume: follows the pointer 1:1,
/// the knob grows while dragged; arrow keys through accessibility.
struct VolumeSlider: View {
    let value: Double
    let accent: Color
    var isKnown = true
    let onChange: (Double) -> Void
    @State private var isDragging = false

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width - 12)
            let fraction = min(1, max(0, value))
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22)).frame(height: 4)
                Capsule().fill(accent).frame(width: 6 + width * fraction, height: 4)
                Circle()
                    .fill(.white)
                    .frame(width: isDragging ? 14 : 11, height: isDragging ? 14 : 11)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .offset(x: width * fraction - (isDragging ? 1 : 0))
                    .opacity(isKnown ? 1 : 0.4)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        isDragging = true
                        onChange(min(1, max(0, (drag.location.x - 6) / width)))
                    }
                    .onEnded { _ in isDragging = false }
            )
            .animation(.snappy(duration: 0.12), value: isDragging)
        }
        .frame(height: 32)
        .accessibilityElement()
        .accessibilityLabel("Volume".l10n)
        .accessibilityValue(ValueFormat.percent(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(min(1, value + 0.1))
            case .decrement: onChange(max(0, value - 0.1))
            @unknown default: break
            }
        }
    }
}

// MARK: - Status

/// A short message: what happened after a click, or why it could not.
struct StatusToast: View {
    let status: PlayerStatus
    let tint: Color
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: status.kind == .problem ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(status.kind == .problem ? Color(red: 1, green: 0.78, blue: 0.35) : .white.opacity(0.9))
            Text(status.text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .widgetGlass(Capsule(), tint: tint)
        .contentShape(Capsule())
        // Hugs short messages; long ones wrap at this width.
        .frame(maxWidth: 540)
        .fixedSize(horizontal: false, vertical: true)
        .onTapGesture(perform: onClose)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}
