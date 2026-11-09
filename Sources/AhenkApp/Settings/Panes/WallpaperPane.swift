import AhenkKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WallpaperPane: View {
    @Bindable var settings: AppSettings
    let wallpaper: WallpaperController
    @State private var displays = DisplayIdentity.currentDisplays()
    @State private var address = ""
    @State private var addressRefused = false

    var body: some View {
        PaneForm(
            pane: .wallpaper,
            summary: "While a song plays, its motion artwork or music video becomes the wallpaper, then fades back into yours.".l10n
        ) {
            Section {
                ToggleRow(title: "Show the live wallpaper".l10n, detail: wallpaper.status.title, isOn: $settings.wallpaper.enabled)
            }

            Section {
                Picker("First choice".l10n, selection: $settings.wallpaper.preferredSource) {
                    Text("Motion artwork".l10n).tag(WallpaperSourcePreference.motionArtwork)
                    Text("Music videos".l10n).tag(WallpaperSourcePreference.musicVideo)
                }
                .pickerStyle(.segmented)
                Toggle("Motion artwork".l10n, isOn: $settings.wallpaper.useMotionArtwork)
                ToggleRow(
                    title: "Music videos".l10n,
                    detail: "The song's own video, or another one by the same artist.".l10n,
                    isOn: $settings.wallpaper.useMusicVideos
                )
                Toggle("The album cover when there is no video".l10n, isOn: $settings.wallpaper.useArtworkFallback)
            } header: {
                Text("Sources".l10n)
            } footer: {
                Text("Motion artwork comes from Apple's catalog, music videos from YouTube's embedded player, muted. Both stream while they show; nothing is downloaded.".l10n)
            }

            Section("Playback".l10n) {
                ToggleRow(
                    title: "Follow the song with its own video".l10n,
                    detail: "It starts where the song is and keeps up with it. Other videos loop.".l10n,
                    isOn: $settings.wallpaper.followSong
                )
                ToggleRow(
                    title: "Go back to your wallpaper when the music pauses".l10n,
                    detail: "When this is off, the paused picture stays.".l10n,
                    isOn: $settings.wallpaper.returnsOnPause
                )
                ToggleRow(
                    title: "Show the dots above the player".l10n,
                    detail: "Choose the video for each song, or type the artist's name.".l10n,
                    isOn: $settings.wallpaper.showPicker
                )
            }

            Section {
                SliderRow(
                    title: "Crossfade".l10n, value: $settings.wallpaper.crossfadeDuration,
                    range: WallpaperSettings.crossfadeRange, step: 0.1, format: ValueFormat.seconds
                )
                SliderRow(
                    title: "Dimming".l10n, value: $settings.wallpaper.dimming,
                    range: WallpaperSettings.dimmingRange, format: ValueFormat.percent
                )
                SliderRow(
                    title: "Blur".l10n, value: $settings.wallpaper.blur,
                    range: WallpaperSettings.blurRange, format: ValueFormat.percent
                )
            } header: {
                Text("Look".l10n)
            } footer: {
                Text("Dimming and a soft shade at the edges keep the clock, the player, the lyrics and the edge light readable over bright videos. On battery and in Optimized Mode videos play at a lower resolution; in Low Power Mode only the cover moves.".l10n)
            }

            Section {
                ForEach(displays) { display in
                    Toggle(isOn: shows(display)) {
                        Text(display.name)
                        if display.isMain {
                            Text("Main display".l10n)
                        }
                    }
                }
            } header: {
                Text("Displays".l10n)
            } footer: {
                Text("A YouTube video plays separately on each display.".l10n)
            }

            Section {
                if settings.wallpaper.savedVideos.isEmpty {
                    EmptyRow(text: "No videos yet. Videos you add appear here.".l10n)
                } else {
                    ForEach(settings.wallpaper.savedVideos) { video in
                        videoRow(video)
                    }
                    if settings.wallpaper.selectedVideoID != nil {
                        Button("Follow the Song Again".l10n) {
                            settings.wallpaper.selectVideo(id: nil)
                        }
                    }
                }
                addRow
            } header: {
                Text("Your Videos".l10n)
            } footer: {
                Text("The video you choose shows instead of the song's while music plays. Files play from where they are; web addresses and YouTube videos stream.".l10n)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displays = DisplayIdentity.currentDisplays()
        }
    }

    private func videoRow(_ video: SavedVideo) -> some View {
        let isShown = settings.wallpaper.selectedVideoID == video.id
        return LabeledContent {
            HStack(spacing: 8) {
                if isShown {
                    Label("On the Desktop".l10n, systemImage: "checkmark")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Show on the Desktop".l10n) {
                        settings.wallpaper.selectVideo(id: video.id)
                    }
                }
                Button("Remove".l10n, role: .destructive) {
                    settings.wallpaper.removeVideo(id: video.id)
                }
            }
        } label: {
            Label {
                Text(video.title)
                Text(video.kind.caption(reference: video.reference))
            } icon: {
                Image(systemName: video.kind.symbol)
            }
        }
    }

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField(text: $address, prompt: Text("YouTube link or video address".l10n)) {
                    Text("Web address".l10n)
                }
                .labelsHidden()
                .onSubmit(addAddress)
                .onChange(of: address) { addressRefused = false }
                Button("Add".l10n, action: addAddress)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Add Video File…".l10n, action: chooseFile)
            }
            if addressRefused {
                Text("That is not a YouTube link or the address of a video.".l10n)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func addAddress() {
        if wallpaper.addVideo(fromAddress: address) {
            address = ""
        } else {
            addressRefused = true
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Add".l10n
        panel.message = "Choose videos for the live wallpaper.".l10n
        panel.begin { response in
            guard response == .OK else { return }
            Task { @MainActor in
                for url in panel.urls { wallpaper.addVideoFile(url) }
            }
        }
    }

    private func shows(_ display: DisplayInfo) -> Binding<Bool> {
        Binding {
            !settings.wallpaper.disabledDisplays.contains(display.id)
        } set: { on in
            if on {
                settings.wallpaper.disabledDisplays.remove(display.id)
            } else {
                settings.wallpaper.disabledDisplays.insert(display.id)
            }
        }
    }
}

extension SavedVideo.Kind {
    var symbol: String {
        switch self {
        case .youtube: "play.rectangle"
        case .file: "film"
        case .url: "link"
        }
    }

    /// Under the title: where it comes from.
    @MainActor
    func caption(reference: String) -> String {
        switch self {
        case .youtube: "YouTube"
        case .file: (reference as NSString).abbreviatingWithTildeInPath
        case .url: URL(string: reference)?.host ?? reference
        }
    }
}

extension WallpaperController.Status {
    /// One line under the switch: what the wallpaper does now.
    @MainActor
    var title: String {
        switch self {
        case .off: "Off".l10n
        case .waitingForMusic: "Waiting for music".l10n
        case .looking: "Looking for videos".l10n
        case .showing(let kind, _):
            switch kind {
            case .motionArtwork: "Showing the album's motion artwork".l10n
            case .songVideo: "Showing the song's video".l10n
            case .artistVideo: "Showing another video by the artist".l10n
            case .userVideo: "Showing your video".l10n
            case .artwork: "Showing the album cover".l10n
            case .generated: "Showing generated motion".l10n
            }
        case .nothingToShow: "Nothing to show for this song".l10n
        case .hidden: "Paused while the desktop is hidden".l10n
        case .everyDisplayOff: "Off on every display".l10n
        }
    }
}
