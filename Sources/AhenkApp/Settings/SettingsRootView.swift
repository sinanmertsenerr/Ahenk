import AhenkKit
import SwiftUI

/// Sidebar with every pane, detail on the right.
struct SettingsRootView: View {
    let environment: AppEnvironment
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        let pane = navigation.selection ?? .general
        NavigationSplitView {
            List(selection: $navigation.selection) {
                ForEach(SettingsPane.groups.indices, id: \.self) { index in
                    Section {
                        ForEach(SettingsPane.groups[index]) { pane in
                            Label {
                                Text(pane.title)
                            } icon: {
                                PaneIcon(pane: pane)
                            }
                            .tag(pane)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            SettingsDetail(pane: pane, environment: environment)
                .navigationTitle(pane.title)
        }
        .toolbar(removing: .sidebarToggle)
        .environment(\.locale, environment.settings.general.language.locale())
        .frame(minWidth: 720, minHeight: 500)
    }
}

/// The pane for one sidebar entry.
struct SettingsDetail: View {
    let pane: SettingsPane
    let environment: AppEnvironment

    var body: some View {
        let settings = environment.settings
        switch pane {
        case .general: GeneralPane(environment: environment, settings: settings)
        case .sources: SourcesPane(services: environment.services, settings: settings)
        case .light: LightPane(settings: settings, light: environment.light)
        case .player: PlayerPane(settings: settings) { environment.desktopPlayer.resetLayout() }
        case .lyrics: LyricsPane(settings: settings)
        case .wallpaper: WallpaperPane(settings: settings)
        case .sound: SoundPane(audio: environment.audio, apps: environment.services.apps, settings: settings)
        case .stickers: StickersPane(settings: settings)
        case .about: AboutPane()
        }
    }
}
