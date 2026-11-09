import AhenkKit
import AppKit
import SwiftUI

/// The live wallpaper's dots above the player: one per thing the wallpaper
/// can show for the playing song (its motion artwork, its own video, other
/// videos by the artist, the cover; then the user's own videos). The one
/// showing is lit; a click shows another (remembered for the song). When no
/// video is found, the artist's name can be typed and searched again.
struct WallpaperPicker: View {
    let model: DesktopPlayerModel
    @State private var isTyping = false
    @State private var artist = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            if let wallpaper = model.wallpaper, wallpaper.phase != .idle || isTyping {
                capsule(wallpaper)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .frame(height: PlayerLayout.pickerHeight)
        .animation(.easeOut(duration: 0.2), value: model.wallpaper?.phase)
        .animation(.easeOut(duration: 0.2), value: isTyping)
    }

    private func capsule(_ wallpaper: WallpaperController) -> some View {
        let theme = model.theme
        return HStack(spacing: 6) {
            if isTyping {
                artistField(wallpaper)
            } else {
                switch wallpaper.phase {
                case .idle:
                    EmptyView()
                case .looking:
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                        .accessibilityLabel("Looking for videos".l10n)
                    dots(wallpaper, accent: theme.accent)
                case .ready:
                    dots(wallpaper, accent: theme.accent)
                case .nothingFound:
                    Text("No video found".l10n)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                    dots(wallpaper, accent: theme.accent)
                }
                typeButton(wallpaper, prominent: wallpaper.phase == .nothingFound)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: PlayerLayout.pickerHeight)
        .widgetGlass(Capsule(), tint: theme.glass)
    }

    @ViewBuilder
    private func dots(_ wallpaper: WallpaperController, accent: Color) -> some View {
        let offer = wallpaper.offer
        let firstUser = offer.firstIndex { $0.kind == .userVideo }
        ForEach(Array(offer.enumerated()), id: \.element.id) { index, candidate in
            if index == firstUser, index > 0 {
                Rectangle()
                    .fill(.white.opacity(0.25))
                    .frame(width: 1, height: 10)
                    .padding(.horizontal, 2)
                    .accessibilityHidden(true)
            }
            WallpaperDot(
                title: candidate.pickerTitle, isCurrent: candidate.id == wallpaper.currentID, accent: accent
            ) {
                wallpaper.choose(candidate.id)
            }
        }
    }

    private func typeButton(_ wallpaper: WallpaperController, prominent: Bool) -> some View {
        Button {
            artist = wallpaper.artistName
            isTyping = true
            isFocused = true
        } label: {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: prominent ? 12.5 : 11, weight: .semibold))
                .foregroundStyle(.white.opacity(prominent ? 0.92 : 0.55))
                .frame(width: 18, height: 18)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Type the artist's name".l10n)
        .accessibilityLabel("Type the artist's name".l10n)
    }

    private func artistField(_ wallpaper: WallpaperController) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.65))
            TextField(text: $artist, prompt: Text("Artist name".l10n).foregroundStyle(.white.opacity(0.45))) {
                Text("Artist name".l10n)
            }
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 170)
            .focused($isFocused)
            .onSubmit {
                wallpaper.searchArtist(artist)
                close()
            }
            .onExitCommand { close() }
            Button {
                close()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Cancel".l10n)
            .accessibilityLabel("Cancel".l10n)
        }
    }

    private func close() {
        isTyping = false
        isFocused = false
        model.onReleaseKeyboard?()
    }
}

/// One dot: lit in the cover's colour when it shows, brighter under the
/// pointer; its title as the tooltip.
private struct WallpaperDot: View {
    let title: String
    let isCurrent: Bool
    let accent: Color
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(isCurrent ? accent : .white.opacity(isHovering ? 0.85 : 0.42))
                .frame(width: isCurrent ? 9 : 7, height: isCurrent ? 9 : 7)
                .overlay {
                    if isCurrent {
                        Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1)
                    }
                }
                .frame(width: 14, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .animation(.easeOut(duration: 0.2), value: isCurrent)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

extension WallpaperCandidate {
    /// The dot's tooltip.
    @MainActor
    var pickerTitle: String {
        switch kind {
        case .motionArtwork: return "The album's motion artwork".l10n
        case .artwork: return "The album cover".l10n
        case .songVideo:
            return title.isEmpty ? "The song's video".l10n : L10n.format("The song's video: %@", title)
        case .artistVideo, .generated:
            return title.isEmpty ? "Another video by the artist".l10n : title
        case .userVideo:
            return L10n.format("Your video: %@", title)
        }
    }
}

/// Every SF Symbol the live wallpaper's dots and Settings use (checked by
/// `--smoke`).
enum WallpaperSymbols {
    static let all = ["person.crop.circle.badge.questionmark", "magnifyingglass", "xmark.circle.fill", "play.rectangle", "film", "link", "checkmark"]
}
