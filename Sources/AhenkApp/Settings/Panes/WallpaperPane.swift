import AhenkKit
import SwiftUI

struct WallpaperPane: View {
    @Bindable var settings: AppSettings

    var body: some View {
        PaneForm(
            pane: .wallpaper,
            summary: "While a song plays, its motion artwork or music video becomes the wallpaper, then fades back into yours.".l10n
        ) {
            Section {
                ToggleRow(title: "Show the live wallpaper".l10n, isOn: $settings.wallpaper.enabled)
            }

            Section("Use".l10n) {
                Toggle("Motion artwork".l10n, isOn: $settings.wallpaper.useMotionArtwork)
                ToggleRow(
                    title: "Music videos".l10n,
                    detail: "The song's own video, or another one by the same artist.".l10n,
                    isOn: $settings.wallpaper.useMusicVideos
                )
                Toggle("The album cover when there is no video".l10n, isOn: $settings.wallpaper.useArtworkFallback)
            }

            Section("Look".l10n) {
                SliderRow(
                    title: "Crossfade".l10n, value: $settings.wallpaper.crossfadeDuration,
                    range: WallpaperSettings.crossfadeRange, step: 0.1, format: ValueFormat.seconds
                )
                SliderRow(
                    title: "Dimming".l10n, value: $settings.wallpaper.dimming,
                    range: WallpaperSettings.dimmingRange, format: ValueFormat.percent
                )
            }

            Section("Your Videos".l10n) {
                if settings.wallpaper.savedVideos.isEmpty {
                    EmptyRow(text: "No videos yet. Videos you add appear here.".l10n)
                } else {
                    ForEach(settings.wallpaper.savedVideos) { video in
                        LabeledContent(video.title) {
                            Button("Remove".l10n, role: .destructive) {
                                settings.wallpaper.savedVideos.removeAll { $0.id == video.id }
                                if settings.wallpaper.selectedVideoID == video.id {
                                    settings.wallpaper.selectedVideoID = nil
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
