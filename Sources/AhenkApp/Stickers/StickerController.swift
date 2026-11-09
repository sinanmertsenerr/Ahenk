import AhenkKit
import AppKit
import Observation
import UniformTypeIdentifiers

/// The user's stickers on the desktop: one window each at the widgets'
/// level, free on a display or stuck on a widget (a child window of the
/// widget's window, so it moves with it and hides with it). Pictures are
/// cut out on this Mac (`StickerCutter`) and kept in Application Support
/// (`StickerStore`); nothing is uploaded.
@MainActor
@Observable
final class StickerController {
    /// The list, in stacking order (the last is in front).
    private(set) var stickers: [Sticker] = []
    /// A photo is being cut out.
    private(set) var isCutting = false
    /// What went wrong last (shown in Settings › Stickers).
    private(set) var problem: String?

    @ObservationIgnored let store: StickerStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private weak var player: DesktopPlayerController?
    @ObservationIgnored private var windows: [UUID: StickerWindow] = [:]
    @ObservationIgnored private var pictures: [UUID: CGImage] = [:]
    @ObservationIgnored private var bordered: [UUID: (border: Bool, image: CGImage, scale: Double)] = [:]
    @ObservationIgnored private var editing: UUID?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var observers: [AnyObject] = []
    @ObservationIgnored private var tokens: [NSObjectProtocol] = []
    @ObservationIgnored var onOpenSettings: (() -> Void)?
    @ObservationIgnored private var isStarted = false
    private let log = AhenkLogger(category: "stickers")

    init(settings: AppSettings, store: StickerStore) {
        self.settings = settings
        self.store = store
        stickers = store.stickers
    }

    /// The windows on screen now (the smoke check).
    var visibleWindows: [UUID: StickerWindow] { windows.filter { $0.value.isVisible } }

    // MARK: Lifecycle

    func start(player: DesktopPlayerController?) {
        guard !isStarted else { return }
        isStarted = true
        self.player = player
        player?.onWidgetsChanged = { [weak self] in self?.layout() }
        let store = self.store
        tasks.append(Task { [weak self] in
            for await list in store.changes() {
                guard let self else { return }
                self.stickers = list
                self.sync()
            }
        })
        let settings = self.settings
        observers.append(ChangeObserver({ settings.stickers }) { [weak self] _ in self?.sync() })
        tokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        })
        sync()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        tasks.forEach { $0.cancel() }
        tasks = []
        observers = []
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens = []
        for id in Array(windows.keys) { closeWindow(id) }
        store.flush()
    }

    // MARK: Windows

    private func sync() {
        let shown = settings.stickers.enabled ? stickers : []
        let ids = Set(shown.map(\.id))
        for id in Array(windows.keys) where !ids.contains(id) { closeWindow(id) }
        for sticker in shown where windows[sticker.id] == nil {
            guard let window = makeWindow(sticker) else { continue }
            windows[sticker.id] = window
        }
        for sticker in shown { refreshPicture(sticker) }
        pictures = pictures.filter { id, _ in stickers.contains { $0.id == id } }
        layout()
    }

    private func makeWindow(_ sticker: Sticker) -> StickerWindow? {
        guard picture(for: sticker.id) != nil else {
            log.error("The picture of sticker \(sticker.id) is missing")
            return nil
        }
        let window = StickerWindow(stickerID: sticker.id, frame: CGRect(x: -30_000, y: -30_000, width: 100, height: 100))
        let view = StickerView(width: sticker.width, aspect: sticker.aspect, rotation: sticker.rotation)
        let id = sticker.id
        view.onChange = { [weak self] _ in self?.editing = id }
        view.onEnd = { [weak self] edit in self?.finishEdit(id, edit) }
        view.makeMenu = { [weak self] in self?.menu(for: id) }
        view.clampWidth = { [weak self, weak window] width in
            let aspect = self?.store.sticker(id: id)?.aspect ?? 1
            return StickerGeometry.clampedWidth(width, aspect: aspect, screen: window?.screen?.visibleFrame.size ?? NSScreen.main?.visibleFrame.size)
        }
        window.contentView = view
        return window
    }

    private func closeWindow(_ id: UUID) {
        guard let window = windows.removeValue(forKey: id) else { return }
        window.parent?.removeChildWindow(window)
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        bordered[id] = nil
    }

    /// The cut-out, decoded once.
    private func picture(for id: UUID) -> CGImage? {
        if let picture = pictures[id] { return picture }
        guard let data = store.imageData(for: id), let image = StickerCutter.image(fromPNG: data) else { return nil }
        pictures[id] = image
        return image
    }

    /// The picture as shown: with the white border when it is on.
    private func refreshPicture(_ sticker: Sticker) {
        let border = settings.stickers.border
        guard let view = windows[sticker.id]?.stickerView else { return }
        if let cached = bordered[sticker.id], cached.border == border { return }
        guard let picture = picture(for: sticker.id) else { return }
        let image = StickerCutter.bordered(picture, border: border)
        let scale = border ? StickerCutter.borderScale(for: picture) : 1
        bordered[sticker.id] = (border, image, scale)
        view.setPicture(image, scale: scale)
    }

    /// Puts every sticker where its placement says, in stacking order;
    /// stickers of hidden widgets hide with them.
    func layout() {
        let displays = Self.displays()
        let widgetWindows = player?.visibleWindows ?? [:]
        let frames = widgetWindows.mapValues(\.frame)
        for sticker in stickers {
            guard let window = windows[sticker.id], let view = window.stickerView, editing != sticker.id else { continue }
            guard let center = StickerGeometry.center(of: sticker.placement, displays: displays, widgets: frames) else {
                window.parent?.removeChildWindow(window)
                window.orderOut(nil)
                continue
            }
            let scale = bordered[sticker.id]?.scale ?? 1
            let size = CGSize(width: sticker.size.width * scale, height: sticker.size.height * scale)
            let frame = StickerGeometry.windowFrame(center: center, size: size)
            if window.frame != frame { window.setFrame(frame, display: false) }
            view.apply(width: sticker.width, aspect: sticker.aspect, rotation: sticker.rotation)
            if let widget = sticker.placement.widget, let parent = widgetWindows[widget] {
                if window.parent !== parent {
                    window.parent?.removeChildWindow(window)
                    parent.addChildWindow(window, ordered: .above)
                }
            } else if let parent = window.parent {
                parent.removeChildWindow(window)
            }
            window.orderFrontRegardless()
        }
    }

    static func displays() -> [StickerDisplay] {
        NSScreen.screens.compactMap { screen in
            DisplayIdentity.stableID(of: screen).map { StickerDisplay(id: $0, frame: screen.frame, visible: screen.visibleFrame) }
        }
    }

    private func finishEdit(_ id: UUID, _ edit: StickerEdit) {
        editing = nil
        guard let sticker = store.sticker(id: id) else { return }
        let frames = (player?.visibleWindows ?? [:]).mapValues(\.frame)
        let placement = StickerGeometry.placement(movedTo: edit.center, from: sticker.placement, displays: Self.displays(), widgets: frames)
        store.update(id: id) { sticker in
            sticker.placement = placement
            sticker.width = Sticker.clampedWidth(edit.width)
            sticker.rotation = StickerGeometry.normalizedRotation(edit.rotation)
        }
        layout()
    }

    // MARK: Actions

    /// Sticks a sticker to a widget where it is now, or frees it.
    func attach(_ id: UUID, to widget: DesktopWidget?) {
        guard let window = windows[id] else { return }
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        let frames = (player?.visibleWindows ?? [:]).mapValues(\.frame)
        let placement: StickerPlacement?
        if let widget, let frame = frames[widget] {
            placement = StickerGeometry.attached(to: widget, frame: frame, center: center)
        } else {
            placement = StickerGeometry.onDesktop(center: center, displays: Self.displays())
        }
        guard let placement else { return }
        store.update(id: id) { $0.placement = placement }
    }

    func bringToFront(_ id: UUID) {
        store.bringToFront(id: id)
    }

    func resetSize(_ id: UUID) {
        guard let sticker = store.sticker(id: id) else { return }
        let width = StickerGeometry.defaultWidth(pixelWidth: sticker.pixelWidth, pixelHeight: sticker.pixelHeight, screen: NSScreen.main?.visibleFrame.size)
        store.update(id: id) {
            $0.width = width
            $0.rotation = 0
        }
    }

    func remove(_ id: UUID) {
        store.remove(id: id)
        log.info("Sticker removed")
    }

    /// The widgets a sticker can stick to now (those on screen).
    var shownWidgets: [DesktopWidget] {
        let shown = player?.visibleWindows.keys.map { $0 } ?? []
        return DesktopWidget.allCases.filter(shown.contains)
    }

    // MARK: Adding

    /// "Add Sticker…": photos picked in an open panel become stickers.
    func pickPhotos(onto widget: DesktopWidget? = nil) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose photos; Ahenk cuts out their subjects on this Mac.".l10n
        panel.prompt = "Make Stickers".l10n
        NSApp.activate()
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor [weak self] in
                for url in urls { await self?.add(photoAt: url, onto: widget) }
            }
        }
    }

    /// Cuts the photo's subject out and puts it on the desktop (at `point`,
    /// stuck on `widget` when dropped on one).
    @discardableResult
    func add(photoAt url: URL, at point: CGPoint? = nil, onto widget: DesktopWidget? = nil) async -> Bool {
        isCutting = true
        defer { isCutting = false }
        do {
            let cutout = try await Task.detached(priority: .userInitiated) { try StickerCutter.cut(photoAt: url) }.value
            return add(cutout, name: url.deletingPathExtension().lastPathComponent, at: point, onto: widget)
        } catch {
            problem = "This picture could not be opened.".l10n
            log.notice("A picture could not be cut out: \(error)")
            return false
        }
    }

    @discardableResult
    func add(_ cutout: StickerCutter.Cutout, name: String, at point: CGPoint? = nil, onto widget: DesktopWidget? = nil) -> Bool {
        let frames = (player?.visibleWindows ?? [:]).mapValues(\.frame)
        let placement = StickerGeometry.newPlacement(at: point, onto: widget, widgets: frames, displays: Self.displays(), existing: stickers.count)
        let width = StickerGeometry.defaultWidth(
            pixelWidth: cutout.image.width, pixelHeight: cutout.image.height, screen: NSScreen.main?.visibleFrame.size
        )
        let sticker = Sticker(name: name, pixelWidth: cutout.image.width, pixelHeight: cutout.image.height, placement: placement, width: width)
        pictures[sticker.id] = cutout.image
        do {
            try store.add(sticker, png: cutout.png)
        } catch StickerStore.StoreError.full {
            pictures[sticker.id] = nil
            problem = "Ahenk keeps up to 60 stickers. Remove one to add another.".l10n
            return false
        } catch {
            pictures[sticker.id] = nil
            problem = "The sticker could not be saved.".l10n
            log.error("Could not save a sticker: \(error)")
            return false
        }
        problem = cutout.foundSubject ? nil : "No subject was found in this photo, so the whole photo became the sticker.".l10n
        if !settings.stickers.enabled { settings.stickers.enabled = true }
        log.info("Sticker added (\(cutout.image.width)×\(cutout.image.height) px, \(cutout.foundSubject ? "subject cut out" : "whole photo"))")
        return true
    }

    /// The demo's sticker: a generated mug cut out by Vision, on the clock.
    func addDemoSticker() async {
        guard stickers.isEmpty, let photo = DemoStickerArt.makeImage(.mug) else { return }
        let image = SendableCGImage(photo)
        let job = Task.detached(priority: .utility) { try StickerCutter.cut(image.image) }
        guard let cutout = try? await job.value else { return }
        let onClock = player?.visibleWindows[.clock].map { CGPoint(x: $0.frame.maxX - 40, y: $0.frame.minY + 50) }
        add(cutout, name: "Mug", at: onClock, onto: onClock == nil ? nil : .clock)
    }

    // MARK: Menu and Settings

    private func menu(for id: UUID) -> NSMenu? {
        guard let sticker = store.sticker(id: id) else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for widget in shownWidgets {
            let item = ClosureMenuItem(title: Self.stickTitle(widget)) { [weak self] in self?.attach(id, to: widget) }
            item.state = sticker.placement.widget == widget ? .on : .off
            menu.addItem(item)
        }
        if sticker.placement.widget != nil {
            menu.addItem(ClosureMenuItem(title: "Leave on the Desktop".l10n) { [weak self] in self?.attach(id, to: nil) })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Bring to Front".l10n) { [weak self] in self?.bringToFront(id) })
        menu.addItem(ClosureMenuItem(title: "Original Size and Angle".l10n) { [weak self] in self?.resetSize(id) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Remove Sticker".l10n) { [weak self] in self?.remove(id) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Add Sticker…".l10n) { [weak self] in self?.pickPhotos() })
        menu.addItem(ClosureMenuItem(title: "Sticker Settings…".l10n) { [weak self] in self?.onOpenSettings?() })
        return menu
    }

    static func stickTitle(_ widget: DesktopWidget) -> String {
        switch widget {
        case .clock: "Stick to the Clock".l10n
        case .continuePlaying: "Stick to the List".l10n
        case .player: "Stick to the Player".l10n
        case .lyrics: "Stick to the Lyrics".l10n
        }
    }

    /// Where a sticker is, in words (Settings › Stickers).
    static func placeText(_ placement: StickerPlacement) -> String {
        switch placement {
        case .desktop: "On the desktop".l10n
        case .widget(.clock, _, _): "On the clock".l10n
        case .widget(.continuePlaying, _, _): "On the list".l10n
        case .widget(.player, _, _): "On the player".l10n
        case .widget(.lyrics, _, _): "On the lyrics".l10n
        }
    }

    /// A small picture for Settings.
    func thumbnail(for id: UUID) -> NSImage? {
        guard let picture = picture(for: id) else { return nil }
        return NSImage(cgImage: picture, size: NSSize(width: picture.width, height: picture.height))
    }

    func clearProblem() {
        problem = nil
    }
}

/// A CGImage handed to a detached task (immutable once made).
struct SendableCGImage: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
