import AhenkKit
import SwiftUI

/// Which page of the guide shows.
@MainActor
@Observable
final class OnboardingModel {
    var page: OnboardingPage = .welcome
}

/// The first-run guide: what Ahenk does, the permissions it uses (each
/// asked only by a button here or in Settings), the browser extension and
/// opening at login. Demo runs show every page but ask for nothing.
struct OnboardingView: View {
    /// Every SF Symbol the guide uses (checked by `--smoke`).
    static let symbols = [
        "light.max", "play.rectangle", "photo.on.rectangle.angled", "dock.rectangle", "waveform", "checkmark.circle.fill",
        "music.note", "mic.slash", "slider.vertical.3", "sparkles", "music.note.list", "info.circle", "hand.raised",
        "arrow.clockwise", "lock", "exclamationmark.triangle.fill", "checkmark", "menubar.rectangle", "leaf", "questionmark.circle",
        "exclamationmark.triangle",
    ]

    let environment: AppEnvironment
    @Bindable var model: OnboardingModel
    /// The guide is finished (the last page's button).
    let done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                page(model.page)
                    .padding(.horizontal, 36)
                    .padding(.top, 20)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            Divider()
            footer
        }
        // The window's content runs under the title bar, so the guide fills
        // the area below it rather than a fixed height that would be pushed
        // down and cut off at the bottom.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.locale, environment.settings.general.language.locale())
        .animation(.easeOut(duration: 0.2), value: model.page)
    }

    @ViewBuilder
    private func page(_ page: OnboardingPage) -> some View {
        switch page {
        case .welcome: WelcomePage(settings: environment.settings)
        case .listening: ListeningPage(audio: environment.audio)
        case .musicApps: MusicAppsPage(services: environment.services)
        case .browser: BrowserPage(services: environment.services)
        case .finish: FinishPage(loginItem: environment.loginItem)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            PageDots(current: model.page)
            Spacer()
            if let previous = model.page.previous {
                Button("Back".l10n) { model.page = previous }
                    .keyboardShortcut(.cancelAction)
            }
            if let next = model.page.next {
                Button("Continue".l10n) { model.page = next }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Start Using Ahenk".l10n, action: done)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.large)
        .padding(20)
    }
}

/// One dot per page, the current one long.
private struct PageDots: View {
    let current: OnboardingPage

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingPage.allCases, id: \.self) { page in
                Capsule()
                    .fill(page == current ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: page == current ? 18 : 7, height: 7)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(L10n.format("Step %d of %d", current.index + 1, OnboardingPage.allCases.count))
    }
}

/// Symbol, title and explanation at the top of a page.
private struct PageTitle: View {
    let symbol: String
    let tint: Color
    let title: String
    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(tint.gradient)
                .frame(width: 52, height: 52)
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .accessibilityHidden(true)
            Text(title)
                .font(.title.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(summary)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A rounded panel that holds a page's controls.
private struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// A short line with a symbol in front.
private struct NoteRow: View {
    let symbol: String
    let text: String

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
        }
        .font(.callout)
    }
}

// MARK: - Pages

private struct WelcomePage: View {
    @Bindable var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 18) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 84, height: 84)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Welcome to Ahenk".l10n)
                        .font(.largeTitle.weight(.semibold))
                    Text("Your desktop, in time with the music.".l10n)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                NoteRow(symbol: "light.max", text: "A light around your screens in the album's colors, moving with the beat".l10n)
                NoteRow(symbol: "play.rectangle", text: "A glass player, a big clock and synced lyrics on the desktop".l10n)
                NoteRow(symbol: "photo.on.rectangle.angled", text: "The song's motion artwork or video as a live wallpaper".l10n)
                NoteRow(symbol: "dock.rectangle", text: "The cover in the Dock, Clear Desk, stickers and sound effects".l10n)
            }
            Card {
                HStack {
                    Text("Language".l10n)
                    Spacer()
                    Picker("Language".l10n, selection: $settings.general.language) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.nativeName).tag(language)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            Text("The next pages ask for what Ahenk needs. Each takes a click, and you can change your mind later in Settings.".l10n)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ListeningPage: View {
    let audio: AudioTapEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageTitle(
                symbol: "waveform", tint: SettingsPane.sound.tint,
                title: "Let the light hear the music".l10n,
                summary: "So the light, the Dock ring and the lyrics' timing can follow the beat, macOS asks once whether Ahenk may hear your Mac's sound.".l10n
            )
            Card {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("System audio access".l10n)
                        Text(audio.isDemo ? "Demo mode asks for nothing.".l10n : audio.permission.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !audio.isDemo {
                        switch audio.permission {
                        case .notDetermined, .unknown:
                            Button("Allow Listening…".l10n) { audio.requestPermission() }
                                .buttonStyle(.borderedProminent)
                        case .denied:
                            Button("Open System Settings…".l10n) { audio.openPrivacySettings() }
                        case .authorized:
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .imageScale(.large)
                                .accessibilityLabel("Allowed".l10n)
                        }
                    }
                }
                if audio.permission == .denied, !audio.isDemo {
                    Text("Turn Ahenk on under Privacy & Security › Screen & System Audio Recording › System Audio Recording Only, then come back.".l10n)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                NoteRow(symbol: "music.note", text: "Ahenk hears only the app that plays your music, and only while it plays.".l10n)
                NoteRow(symbol: "mic.slash", text: "Never the microphone. The sound is analyzed in memory and never recorded.".l10n)
                NoteRow(symbol: "slider.vertical.3", text: "The sound effects for other apps use this same permission: Ahenk mutes that app and plays its sound again with the effects.".l10n)
                NoteRow(symbol: "sparkles", text: "Without it, the light still glows while music plays, with a gentle made-up beat.".l10n)
            }
        }
        .onAppear { audio.refreshPermission() }
    }
}

private struct MusicAppsPage: View {
    let services: NowPlayingServices

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageTitle(
                symbol: "music.note.list", tint: SettingsPane.sources.tint,
                title: "Apple Music and Spotify".l10n,
                summary: "With Automation, Ahenk reads the song, its cover, shuffle, repeat and favorites straight from the app and sends the commands you choose. Without it, Ahenk still shows what plays.".l10n
            )
            Card {
                ForEach([MusicSource.appleMusic, .spotify]) { source in
                    MusicAppRow(source: source, services: services)
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                NoteRow(symbol: "info.circle", text: "macOS can ask only while the app is open. Open it, then press Allow Access here or later in Settings › Sources.".l10n)
                NoteRow(symbol: "hand.raised", text: "Ahenk never opens Music or Spotify by itself; it plays, pauses or skips only when you ask.".l10n)
            }
        }
        .onAppear { services.refreshPermissions() }
    }
}

private struct BrowserPage: View {
    let services: NowPlayingServices

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageTitle(
                symbol: BrowserExtensionInstaller.symbolName, tint: SettingsPane.wallpaper.tint,
                title: "Music in the browser".l10n,
                summary: "YouTube Music, YouTube, Spotify, SoundCloud, Amazon Music, Deezer and TIDAL report exactly what plays through the Ahenk browser extension, and the desktop player plays your picks there.".l10n
            )
            Card {
                HStack {
                    Text("Chrome, Edge, Brave, Arc, Firefox and other browsers".l10n)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Install Browser Extension…".l10n) { BrowserExtensionInstaller.present() }
                }
                if services.browsers.isEmpty {
                    Text("No browser is connected yet. After installing, open a music site.".l10n)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(services.browsers) { browser in
                        ConnectedBrowserRow(browser: browser, services: services)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                NoteRow(
                    symbol: "arrow.clockwise",
                    text: L10n.format(
                        "Installed it before? Reload it on the browser's extensions page so it becomes version %@; the speed of Nightcore and Slowed in a tab needs it.",
                        ExtensionVersion.shipped.description
                    )
                )
                NoteRow(symbol: "lock", text: "The extension talks only to Ahenk on this Mac and asks for no permission.".l10n)
            }
        }
    }
}

/// A browser the extension connected from, with its version.
private struct ConnectedBrowserRow: View {
    let browser: BridgeBrowserSummary
    let services: NowPlayingServices

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(image: browser.bundleIdentifier.flatMap { services.apps.icon(for: $0) }, placeholder: "globe")
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(L10n.format("Extension %@", browser.extensionVersion))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if ExtensionVersion.needsReload(reported: browser.extensionVersion) {
                Label("Reload it".l10n, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Up to date".l10n)
            }
        }
    }

    private var name: String {
        if let bundle = browser.bundleIdentifier { return services.apps.name(for: bundle) }
        return browser.browserName.isEmpty ? "Browser".l10n : browser.browserName
    }
}

private struct FinishPage: View {
    let loginItem: LoginItem

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageTitle(
                symbol: "checkmark", tint: SettingsPane.player.tint,
                title: "Ready when the music is".l10n,
                summary: "Play a song in any music app or site, or drop a folder of songs on the list, and your desktop follows it.".l10n
            )
            Card {
                LoginItemToggle(loginItem: loginItem)
            }
            VStack(alignment: .leading, spacing: 9) {
                NoteRow(symbol: "menubar.rectangle", text: "The menu bar icon holds quick switches, Clear Desk and Settings.".l10n)
                NoteRow(symbol: "leaf", text: "On battery and in Low Power Mode Ahenk runs lighter by itself.".l10n)
                NoteRow(symbol: "questionmark.circle", text: "Open this guide again from the menu bar menu or Settings › General.".l10n)
            }
        }
    }
}
