import AhenkKit
import AppKit

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("ClosureMenuItem is never decoded")
    }

    @objc private func run() {
        handler()
    }
}

extension QuickToggle {
    /// Menu title (English key).
    @MainActor
    var title: String {
        switch self {
        case .edgeLight: "Edge Light".l10n
        case .desktopPlayer: "Desktop Player".l10n
        case .lyrics: "Lyrics".l10n
        case .liveWallpaper: "Live Wallpaper".l10n
        case .dockArt: "Dock Art".l10n
        }
    }

    /// One plain line under the title: what the switch turns on.
    @MainActor
    var detail: String {
        switch self {
        case .edgeLight: "A light around the screen that moves with the music".l10n
        case .desktopPlayer: "The playing song and its buttons on the desktop".l10n
        case .lyrics: "The words, in time with the song".l10n
        case .liveWallpaper: "The song's video as your wallpaper".l10n
        case .dockArt: "The album cover as the Dock icon".l10n
        }
    }

    var symbolName: String {
        switch self {
        case .edgeLight: "light.max"
        case .desktopPlayer: "play.rectangle"
        case .lyrics: "quote.bubble"
        case .liveWallpaper: "photo.on.rectangle.angled"
        case .dockArt: "dock.rectangle"
        }
    }
}

/// The quick-toggle menu shown by the menu bar extra and the Dock icon.
/// Rebuilt every time it opens, so it always reflects the current settings,
/// song and language.
@MainActor
enum QuickMenu {
    enum Placement {
        case menuBar
        /// The system adds Quit and the app's windows to the Dock menu.
        case dock
    }

    /// Every SF Symbol the menus use (checked by `--smoke`).
    static var symbolNames: [String] {
        QuickToggle.allCases.map(\.symbolName) + ["moon", "moon.fill", "lock", "lock.open", "gearshape", "power", "questionmark.circle", BrowserExtensionInstaller.symbolName]
    }

    static func populate(_ menu: NSMenu, environment: AppEnvironment, placement: Placement) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        let settings = environment.settings

        let services = environment.services
        if let snapshot = environment.nowPlaying.snapshot {
            let header = environment.options.usesDemoContent ? "Now Playing (Demo)".l10n : "Now Playing".l10n
            menu.addItem(NSMenuItem.sectionHeader(title: header))
            let song = NSMenuItem(title: snapshot.track.title, action: nil, keyEquivalent: "")
            song.isEnabled = false
            // "Artist · Spotify": where it plays, next to who sings.
            let source = services.state.activeID.map(services.displayName(for:))
            let detail = [snapshot.track.artist, source ?? ""].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
            if #available(macOS 14.4, *), !detail.isEmpty {
                song.subtitle = detail
            } else if !detail.isEmpty {
                song.title = "\(snapshot.track.title) \u{2014} \(detail)"
            }
            if let artwork = environment.nowPlaying.artworkImage {
                song.image = MenuBarIcon.rounded(artwork, size: 32, radius: 6)
            }
            menu.addItem(song)
            menu.addItem(.separator())
        }

        if let conflict = services.state.conflict {
            for item in conflictItems(conflict, services: services) {
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        // Until macOS has been asked, the light cannot hear the music: a
        // hint that asks (only when chosen).
        let audio = environment.audio
        if placement == .menuBar, audio.needsPermission {
            let allow = ClosureMenuItem(title: "Allow Listening…".l10n) { [weak audio] in
                audio?.requestPermission()
            }
            allow.image = symbol("waveform")
            let detail = "So the light can move with the beat".l10n
            if #available(macOS 14.4, *) {
                allow.subtitle = detail
            } else {
                allow.toolTip = detail
            }
            menu.addItem(allow)
            menu.addItem(.separator())
        }

        // What Ahenk draws, one switch each, with a line that says what it is.
        menu.addItem(NSMenuItem.sectionHeader(title: "Features".l10n))
        for toggle in QuickToggle.allCases {
            let item = ClosureMenuItem(title: toggle.title) { [weak settings] in
                settings?.flip(toggle)
            }
            item.state = settings.isOn(toggle) ? .on : .off
            item.image = symbol(toggle.symbolName)
            describe(item, toggle.detail, placement: placement)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: "Desktop".l10n))

        let desk = environment.clearDesk
        let clearDesk = ClosureMenuItem(title: "Clear Desk".l10n) { desk.toggle() }
        clearDesk.isEnabled = desk.isAvailable
        clearDesk.state = desk.isActive ? .on : .off
        clearDesk.image = symbol(desk.isActive ? "moon.fill" : "moon")
        let deskDetail = desk.isActive
            ? "Click again to bring back the apps it hid".l10n
            : "Hides the other apps; click again to bring them back".l10n
        describe(clearDesk, deskDetail, placement: placement)
        menu.addItem(clearDesk)

        let isLocked = settings.player.widgetsLocked
        let lock = ClosureMenuItem(title: "Lock Widgets".l10n) { [weak settings] in
            settings?.player.widgetsLocked.toggle()
        }
        lock.state = isLocked ? .on : .off
        lock.image = symbol(isLocked ? "lock" : "lock.open")
        describe(lock, "The widgets cannot be moved by accident".l10n, placement: placement)
        menu.addItem(lock)

        guard placement == .menuBar else { return }
        menu.addItem(.separator())
        let guide = ClosureMenuItem(title: "Getting Started…".l10n) { [weak environment] in
            environment?.showOnboarding()
        }
        guide.image = symbol("questionmark.circle")
        menu.addItem(guide)
        let install = ClosureMenuItem(title: "Install Browser Extension…".l10n) {
            BrowserExtensionInstaller.present()
        }
        install.image = symbol(BrowserExtensionInstaller.symbolName)
        menu.addItem(install)
        let settingsItem = ClosureMenuItem(title: "Settings…".l10n, keyEquivalent: ",") { [weak environment] in
            environment?.showSettings()
        }
        settingsItem.image = symbol("gearshape")
        menu.addItem(settingsItem)
        let quit = ClosureMenuItem(title: "Quit Ahenk".l10n, keyEquivalent: "q") {
            NSApp.terminate(nil)
        }
        quit.image = symbol("power")
        menu.addItem(quit)
    }

    /// "Which one should Ahenk follow?" and one item per playing player
    /// (its name, its song); choosing one follows it and, if set, pauses
    /// the others.
    static func conflictItems(_ conflict: PlaybackConflict, services: NowPlayingServices) -> [NSMenuItem] {
        var items = [NSMenuItem.sectionHeader(title: "Which one should Ahenk follow?".l10n)]
        for player in conflict.players {
            let item = ClosureMenuItem(title: services.displayName(for: player)) { [weak services] in
                services?.choose(player)
            }
            item.state = player == services.state.activeID ? .on : .off
            if let snapshot = services.state.player(player)?.snapshot, #available(macOS 14.4, *) {
                item.subtitle = [snapshot.track.title, snapshot.track.artist].filter { !$0.isEmpty }.joined(separator: " \u{2014} ")
            }
            if let bundle = player.bundleIdentifier, let icon = services.apps.icon(for: bundle) {
                item.image = MenuBarIcon.rounded(icon, size: 18, radius: 0)
            }
            items.append(item)
        }
        return items
    }

    /// The line under an item's title in the menu bar menu; a tooltip in
    /// the Dock menu and before macOS 14.4, which show no subtitles.
    private static func describe(_ item: NSMenuItem, _ detail: String, placement: Placement) {
        if #available(macOS 14.4, *), placement == .menuBar {
            item.subtitle = detail
        } else {
            item.toolTip = detail
        }
    }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }
}

/// Owns the menu bar extra.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let environment: AppEnvironment
    private var statusItem: NSStatusItem?
    private var titleObserver: ChangeObserver<String?>?
    private var conflictObserver: ChangeObserver<Bool>?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = MenuBarIcon.image
        item.button?.imagePosition = .imageLeading
        item.button?.setAccessibilityTitle("Ahenk")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        // Optional song title next to the icon (General › Menu bar).
        titleObserver = ChangeObserver({ [weak self] in self?.menuBarTitle }) { [weak self] title in
            self?.statusItem?.button?.title = title.map { " \($0)" } ?? ""
        }
        statusItem?.button?.title = menuBarTitle.map { " \($0)" } ?? ""
        // A dot on the icon while several sources play: the menu asks.
        conflictObserver = ChangeObserver({ [weak self] in self?.environment.services.state.conflict != nil }) { [weak self] waiting in
            self?.statusItem?.button?.image = waiting ? MenuBarIcon.attention : MenuBarIcon.image
        }
    }

    private var menuBarTitle: String? {
        guard environment.settings.general.showSongTitleInMenuBar,
              let track = environment.nowPlaying.snapshot?.track
        else { return nil }
        return track.title
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        QuickMenu.populate(menu, environment: environment, placement: .menuBar)
        // For the next time the menu opens (read without a prompt).
        environment.audio.refreshPermission()
    }
}

/// The app's main menu (shown while Ahenk is the active app).
@MainActor
enum MainMenu {
    static func build(environment: AppEnvironment) -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(ClosureMenuItem(title: "About Ahenk".l10n) { [weak environment] in
            environment?.showSettings(.about)
        })
        app.addItem(.separator())
        app.addItem(ClosureMenuItem(title: "Settings…".l10n, keyEquivalent: ",") { [weak environment] in
            environment?.showSettings()
        })
        app.addItem(ClosureMenuItem(title: "Install Browser Extension…".l10n) {
            BrowserExtensionInstaller.present()
        })
        app.addItem(ClosureMenuItem(title: "Getting Started…".l10n) { [weak environment] in
            environment?.showOnboarding()
        })
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Ahenk".l10n, action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(
            withTitle: "Hide Others".l10n,
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All".l10n, action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Ahenk".l10n, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(app, title: "Ahenk", to: main)

        let edit = NSMenu(title: "Edit".l10n)
        edit.addItem(withTitle: "Undo".l10n, action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo".l10n, action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut".l10n, action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy".l10n, action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste".l10n, action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All".l10n, action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(edit, title: edit.title, to: main)

        let window = NSMenu(title: "Window".l10n)
        window.addItem(withTitle: "Minimize".l10n, action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close".l10n, action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front".l10n, action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        add(window, title: window.title, to: main)
        NSApp.windowsMenu = window

        return main
    }

    private static func add(_ submenu: NSMenu, title: String, to main: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        main.addItem(item)
    }
}
