import AhenkKit
import AppKit
import SwiftUI

/// The lyrics on the desktop: the lines beside the album cover (drawn by
/// `LyricsStageView`, never by SwiftUI), and, under the pointer, a small
/// bar to nudge the timing, pick another version, search for the lyrics,
/// open the sound effects, show or hide the cover and change the style.
/// "Other Lyrics", "Search Lyrics" and "Sound Effects" open as a glass
/// panel over the lines.
struct LyricsWidget: View {
    let lyrics: LyricsController
    let player: DesktopPlayerModel
    let power: PowerMonitor
    @Bindable var settings: AppSettings
    /// The sound effects and what they need to explain themselves; without
    /// them the bar has no effects button.
    var effects: SoundEffectsController?
    var audio: AudioTapEngine?
    /// Times plain lyrics on this Mac (Beta); without it there is no
    /// "Align Lyrics".
    var aligner: LyricsAlignmentController?
    /// Shows the bar without the pointer (offscreen checks).
    var showsBar = false
    @State private var isHovering = false

    var body: some View {
        let theme = player.theme
        ZStack(alignment: .bottom) {
            LyricsStage(lyrics: lyrics, nowPlaying: lyrics.nowPlaying, settings: settings.lyrics, maximumFrameRate: frameRate)
                .opacity(lyrics.panel == nil ? 1 : 0)
                .accessibilityLabel("Lyrics".l10n)
            if let panel = lyrics.panel {
                LyricsPanel(lyrics: lyrics, panel: panel, theme: theme, effects: effects, audio: audio, aligner: aligner, settings: settings)
                    .padding(10)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
            if lyrics.panel == nil {
                // Bottom right: clear of the cover and of the line being sung.
                LyricsBar(lyrics: lyrics, settings: settings, theme: theme, effects: effects, canAlign: aligner != nil)
                    .padding([.bottom, .trailing], 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .opacity(isHovering || showsBar ? 1 : 0)
                    .allowsHitTesting(isHovering || showsBar)
            }
            if let notice = lyrics.notice {
                Text(notice)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .widgetGlass(Capsule(), tint: theme.glass)
                    .padding(.bottom, 56)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .movesWidget()
        .animation(.easeOut(duration: 0.18), value: isHovering)
        .animation(.smooth(duration: 0.24), value: lyrics.panel)
        .animation(.easeOut(duration: 0.2), value: lyrics.notice)
        .environment(\.colorScheme, .dark)
    }

    /// Lighter on battery, in Low Power Mode, in Optimized Mode and when hot.
    private var frameRate: Float {
        let general = settings.general
        let lighter = general.optimizedMode || power.isLowPowerMode || power.isThermallyConstrained
            || (general.lighterOnBattery && power.isOnBattery)
        return lighter ? 30 : 60
    }
}

/// Hands the song, its lyrics, the clock and the look to the AppKit stage.
/// SwiftUI updates it only when one of them changes (a new song, a pause, a
/// seek, a setting), never per frame.
struct LyricsStage: NSViewRepresentable {
    let lyrics: LyricsController
    let nowPlaying: NowPlayingModel
    let settings: LyricsSettings
    let maximumFrameRate: Float

    func makeNSView(context: Context) -> LyricsStageView {
        LyricsStageView(frame: .zero)
    }

    func updateNSView(_ view: LyricsStageView, context: Context) {
        let snapshot = nowPlaying.snapshot
        let track = lyrics.song ?? snapshot?.track
        view.features = nowPlaying.featureSource
        view.maximumFrameRate = maximumFrameRate
        view.content = LyricsStageContent(
            phase: lyrics.stagePhase,
            timeline: lyrics.timeline,
            songID: track.map { "\($0.source.rawValue):\($0.id)" } ?? "",
            title: track?.title ?? "",
            artist: track?.artist ?? "",
            style: settings.style,
            palette: nowPlaying.artwork?.palette ?? .neutral,
            useAlbumColors: settings.useAlbumColors,
            textScale: settings.textScale,
            showsCover: settings.showAlbumArt,
            countdown: settings.instrumentalCountdown
        )
        view.cover = nowPlaying.artwork?.image
        view.clock = snapshot.map {
            LyricsStageClock(
                elapsed: $0.elapsedTime, anchor: $0.timestamp, rate: $0.playbackRate,
                offset: lyrics.offset, duration: $0.track.duration
            )
        }
    }
}

// MARK: - The bar under the pointer

/// Timing (earlier, the offset, later), Other Lyrics, Search Lyrics, the
/// cover, and a menu with the styles.
private struct LyricsBar: View {
    let lyrics: LyricsController
    @Bindable var settings: AppSettings
    let theme: PlayerTheme
    var effects: SoundEffectsController?
    var canAlign = false

    /// Words without timing (or none yet): timing them is what is missing.
    private var offersAlignment: Bool {
        canAlign && settings.lyrics.localAlignment && [.plain, .notFound, .failed].contains(lyrics.phase)
    }

    var body: some View {
        HStack(spacing: 2) {
            if lyrics.phase == .synced {
                WidgetIconButton(symbol: "minus", pointSize: 12, side: 30, help: "Show the lines later".l10n) {
                    lyrics.nudge(by: -LyricsController.nudgeStep)
                }
                Text(Self.offsetText(lyrics.songOffset))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(lyrics.songOffset == 0 ? 0.55 : 0.95))
                    .frame(minWidth: 52)
                    .help("Timing of this song's lyrics".l10n)
                    .accessibilityLabel("Timing of this song's lyrics".l10n)
                    .accessibilityValue(Self.offsetText(lyrics.songOffset))
                WidgetIconButton(symbol: "plus", pointSize: 12, side: 30, help: "Show the lines earlier".l10n) {
                    lyrics.nudge(by: LyricsController.nudgeStep)
                }
                Divider().frame(height: 18).overlay(Color.white.opacity(0.15)).padding(.horizontal, 4)
            }
            WidgetIconButton(symbol: "square.stack", pointSize: 13, side: 30, help: "Other Lyrics".l10n) {
                lyrics.panel = .versions
            }
            WidgetIconButton(symbol: "magnifyingglass", pointSize: 13, side: 30, help: "Search Lyrics".l10n) {
                lyrics.panel = .search
            }
            if offersAlignment {
                WidgetIconButton(symbol: "wand.and.stars", pointSize: 13, side: 30, accent: theme.accent, help: "Align Lyrics to the Song (Beta)".l10n) {
                    lyrics.panel = .align
                }
            }
            if effects != nil {
                // Lit while the effects are switched on.
                WidgetIconButton(
                    symbol: "slider.vertical.3", pointSize: 13, side: 30, isOn: settings.effects.enabled, accent: theme.accent,
                    help: "Sound Effects".l10n
                ) {
                    lyrics.panel = .effects
                }
            }
            WidgetIconButton(
                symbol: "photo", pointSize: 13, side: 30, isOn: settings.lyrics.showAlbumArt, accent: theme.accent,
                help: settings.lyrics.showAlbumArt ? "Hide the Album Cover".l10n : "Show the Album Cover".l10n
            ) {
                settings.lyrics.showAlbumArt.toggle()
            }
            LyricsMoreMenu(lyrics: lyrics, settings: settings, canAlign: canAlign)
        }
        .padding(.horizontal, 6)
        .frame(height: 40)
        .widgetGlass(Capsule(), tint: theme.glass)
    }

    /// "+0.4 s", "−0.2 s", "0 s" in the app's language.
    static func offsetText(_ value: Double) -> String {
        ValueFormat.signedSeconds(value)
    }
}

private struct LyricsMoreMenu: View {
    let lyrics: LyricsController
    @Bindable var settings: AppSettings
    var canAlign = false

    var body: some View {
        Menu {
            Picker("Style".l10n, selection: $settings.lyrics.style) {
                ForEach(LyricStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            Divider()
            Button("Reset the Timing".l10n, systemImage: "arrow.counterclockwise") { lyrics.resetOffset() }
                .disabled(lyrics.songOffset == 0)
            if lyrics.choice != nil {
                Button("Use the Lyrics Ahenk Found".l10n, systemImage: "sparkles") { lyrics.useAutomatic() }
            }
            if canAlign, settings.lyrics.localAlignment, lyrics.phase != .loading {
                Button("Align Lyrics to the Song (Beta)".l10n, systemImage: "wand.and.stars") { lyrics.panel = .align }
            }
            Divider()
            Button("Lyrics Settings…".l10n, systemImage: "gearshape") { lyrics.onOpenSettings?() }
            Button("Hide Lyrics".l10n, systemImage: "eye.slash") { settings.lyrics.enabled = false }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 30, height: 30)
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

// MARK: - Panels

/// "Other Lyrics", "Search Lyrics" or "Sound Effects" over the lines.
private struct LyricsPanel: View {
    let lyrics: LyricsController
    let panel: LyricsController.Panel
    let theme: PlayerTheme
    var effects: SoundEffectsController?
    var audio: AudioTapEngine?
    var aligner: LyricsAlignmentController?
    @Bindable var settings: AppSettings

    private var title: String {
        switch panel {
        case .versions: "Other Lyrics".l10n
        case .search: "Search Lyrics".l10n
        case .effects: "Sound Effects".l10n
        case .align: "Align Lyrics".l10n
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if panel == .search, lyrics.phase != .idle {
                    WidgetIconButton(symbol: "chevron.left", pointSize: 13, side: 28, help: "Other Lyrics".l10n) {
                        lyrics.panel = .versions
                    }
                }
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .textCase(.uppercase)
                    .kerning(0.5)
                if panel == .align { BetaBadge() }
                Spacer(minLength: 8)
                if panel == .versions || panel == .align {
                    Button {
                        lyrics.panel = .search
                    } label: {
                        Label("Search Lyrics".l10n, systemImage: "magnifyingglass")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.accent)
                    }
                    .buttonStyle(.plain)
                }
                if panel == .effects, let effects {
                    SoundEffectsSwitch(effects: effects, settings: settings, accent: theme.accent)
                }
                WidgetIconButton(symbol: "xmark", pointSize: 11.5, side: 28, help: "Close".l10n) {
                    lyrics.panel = nil
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            switch panel {
            case .versions: LyricsVersionList(lyrics: lyrics, theme: theme)
            case .search: LyricsSearchView(lyrics: lyrics, theme: theme)
            case .effects:
                if let effects, let audio {
                    SoundEffectsPanel(effects: effects, audio: audio, settings: settings, theme: theme)
                }
            case .align:
                if let aligner {
                    LyricsAlignPanel(aligner: aligner, lyrics: lyrics, theme: theme)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetGlass(RoundedRectangle(cornerRadius: 22, style: .continuous), tint: theme.glass)
    }
}

/// Every version the providers have for the song; the one shown is ticked.
private struct LyricsVersionList: View {
    let lyrics: LyricsController
    let theme: PlayerTheme

    var body: some View {
        switch lyrics.versions {
        case .idle, .loading:
            WidgetMessage(text: "Looking for other versions…".l10n, isLoading: true)
        case .failed(let message):
            WidgetMessage(symbol: "wifi.exclamationmark", text: message)
        case .loaded(let versions) where versions.isEmpty:
            WidgetMessage(symbol: "text.magnifyingglass", text: "No other versions were found. Try searching with other words.".l10n)
        case .loaded(let versions):
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(versions) { version in
                        LyricsVersionRow(version: version, isCurrent: isCurrent(version), isLoading: lyrics.choosing == version.id, accent: theme.accent) {
                            lyrics.choose(version)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 14)
            }
            .scrollIndicators(.never)
            .fadesScrollEdges()
        }
    }

    private func isCurrent(_ version: LyricsVersion) -> Bool {
        if let choice = lyrics.choice { return choice.id == version.id }
        guard version.provider == lyrics.source, case .synced(let shown) = version.lyrics ?? .notFound, let current = lyrics.lyrics else {
            return false
        }
        return shown.timingFingerprint == current.timingFingerprint
    }
}

/// Title and artist to look for, and what the providers found.
private struct LyricsSearchView: View {
    @Bindable var lyrics: LyricsController
    let theme: PlayerTheme
    @FocusState private var focused: Field?

    private enum Field {
        case title
        case artist
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                field("Song".l10n, text: $lyrics.searchTitle, focus: .title)
                field("Artist".l10n, text: $lyrics.searchArtist, focus: .artist)
                CapsuleButton(title: "Search".l10n, symbol: "magnifyingglass", filled: true, accent: theme.accent) {
                    lyrics.search()
                }
            }
            .padding(.horizontal, 12)
            results
        }
        .onAppear { focused = .title }
    }

    private func field(_ title: String, text: Binding<String>, focus: Field) -> some View {
        TextField(text: text, prompt: Text(title).foregroundStyle(.white.opacity(0.45))) {
            Text(title)
        }
        .textFieldStyle(.plain)
        .font(.system(size: 13.5, weight: .medium))
        .foregroundStyle(.white)
        .focused($focused, equals: focus)
        .onSubmit { lyrics.search() }
        .onExitCommand { lyrics.panel = nil }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(Capsule().fill(.white.opacity(0.1)))
        .overlay(Capsule().strokeBorder(theme.accent.opacity(focused == focus ? 0.6 : 0), lineWidth: 1))
    }

    @ViewBuilder
    private var results: some View {
        switch lyrics.results {
        case .idle:
            WidgetMessage(symbol: "text.magnifyingglass", text: "Type the song and the artist, then press Return.".l10n)
        case .loading:
            WidgetMessage(text: "Searching…".l10n, isLoading: true)
        case .failed(let message):
            WidgetMessage(symbol: "wifi.exclamationmark", text: message)
        case .loaded(let found) where found.isEmpty:
            WidgetMessage(symbol: "text.magnifyingglass", text: "No lyrics were found. Check the spelling or try fewer words.".l10n)
        case .loaded(let found):
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(found) { version in
                        LyricsVersionRow(version: version, isCurrent: lyrics.choice?.id == version.id, isLoading: lyrics.choosing == version.id, accent: theme.accent) {
                            lyrics.choose(version)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 14)
            }
            .scrollIndicators(.never)
            .fadesScrollEdges()
        }
    }
}

/// One version: title and artist, where it comes from, whether it is
/// timed, its length and album.
private struct LyricsVersionRow: View {
    let version: LyricsVersion
    let isCurrent: Bool
    let isLoading: Bool
    let accent: Color
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isCurrent ? accent : .white.opacity(0.6))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text([version.title, version.artist].filter { !$0.isEmpty }.joined(separator: " \u{2014} "))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(details)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if isLoading {
                    ProgressView().controlSize(.small).tint(.white)
                } else if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(accent)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .rowHighlight(isPlaying: isCurrent, accent: accent, cornerRadius: 10)
        .accessibilityLabel("\(version.title), \(details)")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private var symbol: String {
        switch version.kind {
        case .synced: "text.line.first.and.arrowtriangle.forward"
        case .plain: "text.alignleft"
        case .instrumental: "music.note"
        case .unknown: "quote.bubble"
        }
    }

    private var details: String {
        var parts = [LyricsController.displayName(ofProvider: version.provider)]
        switch version.kind {
        case .synced:
            if let count = version.lineCount {
                parts.append(L10n.format("Synced, %d lines", count))
            } else {
                parts.append("Synced".l10n)
            }
        case .plain: parts.append("Words only".l10n)
        case .instrumental: parts.append("Instrumental".l10n)
        case .unknown: break
        }
        if let duration = version.duration, duration > 0 { parts.append(DurationText.string(duration)) }
        if let album = version.album, !album.isEmpty { parts.append(album) }
        return parts.joined(separator: " \u{00B7} ")
    }
}
