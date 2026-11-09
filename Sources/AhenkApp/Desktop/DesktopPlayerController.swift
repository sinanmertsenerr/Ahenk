import AhenkKit
import AppKit
import SwiftUI

/// Puts the desktop widgets on the chosen display: the clock, Continue
/// Playing, the player and the lyrics, each in its own desktop-level
/// window, plus the queue panel beside the player when it is open. The
/// lyrics show while a song with lyrics to look for plays, also when the
/// rest of the player is turned off.
///
/// - Positions are saved per display (`settings.layout`), relative to the
///   display's visible frame, when a drag ends; widgets without a saved
///   position use the default layout (clock top left, the list under it,
///   the player in the lower middle).
/// - The player window is anchored at its bottom centre: it grows upwards
///   at once when a page or the search opens and shrinks after the content
///   has faded out, so the bar never moves.
/// - The clock ticks only while its window can be seen; the progress line
///   and the playing bars stop by themselves when hidden.
/// - Turning the player off (menu bar, Settings) closes every window; the
///   queue keeps playing.
@MainActor
final class DesktopPlayerController {
    let model: DesktopPlayerModel
    let clock: ClockModel
    let lyrics: LyricsController
    /// The sound effects behind the button beside the lyrics (set before
    /// the widgets are made).
    var effects: SoundEffectsController?
    var audio: AudioTapEngine?
    /// "Align Lyrics" beside the lyrics.
    var aligner: LyricsAlignmentController?

    private let settings: AppSettings
    private let power: PowerMonitor
    private var windows: [DesktopWidget: DesktopWidgetWindow] = [:]
    private var movers: [DesktopWidget: WidgetMover] = [:]
    /// Where each widget's anchor sits (saved or default), so a widget that
    /// changes size keeps its place.
    private var anchors: [DesktopWidget: NormalizedPoint] = [:]
    private var queueWindow: DesktopWidgetWindow?
    private var occlusionTokens: [DesktopWidget: NSObjectProtocol] = [:]
    private var observers: [AnyObject] = []
    private var tokens: [NSObjectProtocol] = []
    private var screenID: String?
    private var visibleFrame: CGRect = .zero
    private var pendingShrink: DispatchWorkItem?
    private var releasePending = false
    private var isStarted = false
    private let log = AhenkLogger(category: "player")

    /// The list's glass is this wide and at most this tall.
    static let listSize = CGSize(width: 300, height: 500)
    /// The queue panel is at least this tall (beside the small player).
    static let queueMinimumHeight: CGFloat = 440
    /// Content fades out before its window shrinks.
    static let shrinkDelay: TimeInterval = 0.32

    init(settings: AppSettings, nowPlaying: NowPlayingModel, services: NowPlayingServices, lyrics: LyricsController, power: PowerMonitor, demo: DemoProvider?) {
        self.settings = settings
        self.lyrics = lyrics
        self.power = power
        model = DesktopPlayerModel(settings: settings, nowPlaying: nowPlaying, services: services, demo: demo)
        clock = ClockModel(settings: settings)
        model.onResetLayout = { [weak self] in self?.resetLayout() }
        model.onReleaseKeyboard = { [weak self] in self?.windows[.player]?.releaseKeyboard() }
        lyrics.onReleaseKeyboard = { [weak self] in self?.windows[.lyrics]?.releaseKeyboard() }
        lyrics.onFocusSearch = { [weak self] in self?.windows[.lyrics]?.makeKey() }
    }

    var isShowing: Bool { !windows.isEmpty }

    /// Widgets appeared, went away, moved or changed size (stickers on them
    /// follow).
    var onWidgetsChanged: (() -> Void)?

    /// The windows on screen now (smoke checks).
    var visibleWindows: [DesktopWidget: NSWindow] { windows }

    // MARK: Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true
        model.start()
        let settings = self.settings
        let model = self.model
        observers.append(ChangeObserver({ settings.player }) { [weak self] _ in self?.apply() })
        let lyrics = self.lyrics
        observers.append(ChangeObserver({ LyricsWindowState(settings: settings.lyrics, hasSong: lyrics.hasSong) }) { [weak self] state in
            self?.lyricsChanged(state)
        })
        observers.append(ChangeObserver({ settings.general.language }) { [weak self] _ in self?.apply() })
        observers.append(ChangeObserver({ model.layoutState }) { [weak self] _ in self?.resizePlayer() })
        observers.append(ChangeObserver({ model.isQueueOpen }) { [weak self] _ in self?.updateQueue() })
        observers.append(ChangeObserver({ model.focusRequest }) { [weak self] _ in self?.focusSearch() })
        tokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        })
        apply()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        observers = []
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
        tokens = []
        hideAll()
        model.stop()
    }

    /// Back to the default layout on this display.
    func resetLayout() {
        guard let screenID else { return }
        settings.layout.resetPositions(on: screenID)
        anchors = [:]
        placeAll(resizePlayer: true)
        log.info("Desktop widgets back in their default places")
    }

    // MARK: Showing

    private func apply() {
        let player = settings.player
        guard player.enabled || settings.lyrics.enabled, let screen = targetScreen(), let id = DisplayIdentity.stableID(of: screen) else {
            hideAll()
            return
        }
        if id != screenID { anchors = [:] }
        screenID = id
        visibleFrame = screen.visibleFrame
        let wanted = Set(DesktopWidget.allCases.filter(shouldShow))
        for widget in windows.keys where !wanted.contains(widget) {
            close(widget)
        }
        var created: [DesktopWidget] = []
        for widget in DesktopWidget.allCases where wanted.contains(widget) && windows[widget] == nil {
            windows[widget] = makeWindow(widget)
            created.append(widget)
        }
        placeAll(resizePlayer: created.contains(.player))
        for widget in created {
            windows[widget]?.orderFrontRegardless()
        }
        model.setPresented(windows.keys.contains { $0 != .lyrics })
        clockVisibilityChanged()
        updateQueue()
        onWidgetsChanged?()
    }

    private func shouldShow(_ widget: DesktopWidget) -> Bool {
        let player = settings.player
        switch widget {
        case .clock: return player.enabled && player.showClock
        case .continuePlaying: return player.enabled && player.showContinuePlaying
        case .player: return player.enabled && !model.layoutState.isEmpty
        case .lyrics: return settings.lyrics.enabled && lyrics.hasSong
        }
    }

    /// What the lyrics window depends on.
    private struct LyricsWindowState: Equatable {
        var settings: LyricsSettings
        var hasSong: Bool
    }

    private var lastLyricsState: LyricsWindowState?

    private func lyricsChanged(_ state: LyricsWindowState) {
        defer { lastLyricsState = state }
        if let last = lastLyricsState, last.settings.position != state.settings.position, let screenID {
            // A position picked in Settings replaces the dragged place.
            settings.layout.setPosition(nil, of: DesktopWidget.lyrics.rawValue, on: screenID)
            anchors[.lyrics] = nil
        }
        let sizeChanged = lastLyricsState.map { $0.settings.textScale != state.settings.textScale || $0.settings.showAlbumArt != state.settings.showAlbumArt } ?? false
        apply()
        if sizeChanged { placeAll(resizePlayer: false) }
    }

    private func hideAll() {
        pendingShrink?.cancel()
        closeQueue()
        for widget in Array(windows.keys) { close(widget) }
        model.setPresented(false)
        clock.pause()
    }

    private func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        if let id = settings.player.displayID, let match = screens.first(where: { DisplayIdentity.stableID(of: $0) == id }) {
            return match
        }
        return screens.first
    }

    // MARK: Windows

    private func makeWindow(_ widget: DesktopWidget) -> DesktopWidgetWindow {
        let window = DesktopWidgetWindow(widget: widget, frame: CGRect(x: visibleFrame.midX, y: visibleFrame.midY, width: 10, height: 10))
        let mover = WidgetMover()
        mover.window = window
        mover.clamp = { [weak self] frame in
            guard let self else { return frame }
            return WidgetPlacement.clamp(frame, into: self.visibleFrame)
        }
        mover.onMoved = { [weak self] frame in self?.moved(widget, to: frame) }
        movers[widget] = mover
        // The player's search and the lyrics search take the keyboard.
        window.allowsKeyboard = widget == .player || widget == .lyrics
        window.contentView = DesktopHostingView(rootView: AnyView(
            WidgetRoot(settings: settings) { self.root(for: widget) }
                .acceptsFileDrops(model: model, widget: widget)
                .environment(\.widgetMover, mover)
        ))
        // SwiftUI focuses the first text field of a new window; the field
        // waits for a click instead.
        window.initialFirstResponder = nil
        DispatchQueue.main.async { [weak window] in
            if window?.isKeyWindow == false { window?.makeFirstResponder(nil) }
        }
        occlusionTokens[widget] = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.clockVisibilityChanged() }
        }
        return window
    }

    @ViewBuilder
    private func root(for widget: DesktopWidget) -> some View {
        switch widget {
        case .clock: ClockRoot(clock: clock, model: model, settings: settings)
        case .continuePlaying: ContinuePlayingWidget(model: model)
        case .player: PlayerWidget(model: model)
        case .lyrics: LyricsWidget(lyrics: lyrics, player: model, power: power, settings: settings, effects: effects, audio: audio, aligner: aligner)
        }
    }

    private func close(_ widget: DesktopWidget) {
        if widget == .player { closeQueue() }
        if let token = occlusionTokens.removeValue(forKey: widget) {
            NotificationCenter.default.removeObserver(token)
        }
        guard let window = windows.removeValue(forKey: widget) else { return }
        movers[widget] = nil
        // Stickers on it go away with it, without being closed.
        for child in window.childWindows ?? [] where child is StickerWindow {
            window.removeChildWindow(child)
            child.orderOut(nil)
        }
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        releaseClosedWindows()
    }

    /// AppKit lets go of closed windows when it handles its next event, and a
    /// background app can go a long time without one: a no-op event lets the
    /// closed widgets go now.
    private func releaseClosedWindows() {
        guard !releasePending else { return }
        releasePending = true
        DispatchQueue.main.async { [weak self] in
            self?.releasePending = false
            guard let event = NSEvent.otherEvent(
                with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, subtype: 0, data1: 0, data2: 0
            ) else { return }
            NSApp.postEvent(event, atStart: false)
        }
    }

    // MARK: Placement

    private func size(of widget: DesktopWidget) -> CGSize {
        switch widget {
        case .clock:
            let hosting = NSHostingView(rootView: ClockWidget(clock: clock, model: model, settings: settings.player, measuring: true))
            let fitting = hosting.fittingSize
            return CGSize(width: ceil(fitting.width), height: ceil(fitting.height))
        case .continuePlaying:
            let margin = ContinuePlayingWidget.margin
            return CGSize(width: Self.listSize.width + 2 * margin, height: Self.listSize.height + 2 * margin)
        case .player:
            // An open window keeps its size here; `resizePlayer` changes it.
            if let window = windows[.player], window.frame.width > 20 { return window.frame.size }
            return PlayerLayout.size(model.layoutState)
        case .lyrics:
            let lyrics = settings.lyrics
            return LyricsLayout.widgetSize(textScale: lyrics.textScale, showsCover: lyrics.showAlbumArt)
        }
    }

    /// Puts every window at its saved place, or the default one.
    private func placeAll(resizePlayer: Bool) {
        guard let screenID else { return }
        var sizes: [DesktopWidget: CGSize] = [:]
        for widget in windows.keys {
            sizes[widget] = widget == .player && resizePlayer ? PlayerLayout.size(model.layoutState) : size(of: widget)
        }
        let defaults = WidgetPlacement.defaultFrames(sizes: sizes, in: visibleFrame, lyrics: settings.lyrics.position)
        for (widget, window) in windows {
            guard let base = defaults[widget] else { continue }
            let anchor = settings.layout.position(of: widget.rawValue, on: screenID)
                ?? anchors[widget]
                ?? WidgetPlacement.normalizedAnchor(of: base, anchor: widget.anchor, in: visibleFrame)
            anchors[widget] = anchor
            let frame = WidgetPlacement.frame(size: base.size, anchor: widget.anchor, at: anchor, in: visibleFrame)
            if window.frame != frame { window.setFrame(frame, display: true) }
        }
        positionQueue()
        onWidgetsChanged?()
    }

    /// A drag ended: remember where, on this display.
    private func moved(_ widget: DesktopWidget, to frame: CGRect) {
        guard let screenID else { return }
        let anchor = WidgetPlacement.normalizedAnchor(of: frame, anchor: widget.anchor, in: visibleFrame)
        anchors[widget] = anchor
        settings.layout.setPosition(anchor, of: widget.rawValue, on: screenID)
        // The queue may have room beside the player now (or no more).
        updateQueue()
        onWidgetsChanged?()
    }

    /// The player's content changed size: grow now, shrink once the content
    /// has faded out, always around the bar's place.
    private func resizePlayer() {
        guard let window = windows[.player] else {
            // Hidden parts may now be shown (or the other way round).
            if settings.player.enabled { apply() }
            return
        }
        if model.layoutState.isEmpty {
            apply()
            return
        }
        let target = PlayerLayout.size(model.layoutState)
        let current = window.frame.size
        pendingShrink?.cancel()
        pendingShrink = nil
        guard target != current else { return }
        if target.width < current.width || target.height < current.height {
            // Grow what grows at once; shrink the rest after the fade.
            let interim = CGSize(width: max(target.width, current.width), height: max(target.height, current.height))
            if interim != current { setPlayerSize(interim) }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.setPlayerSize(PlayerLayout.size(self.model.layoutState))
            }
            pendingShrink = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.shrinkDelay, execute: work)
        } else {
            setPlayerSize(target)
        }
    }

    private func setPlayerSize(_ size: CGSize) {
        guard let window = windows[.player] else { return }
        let anchor = anchors[.player] ?? WidgetPlacement.normalizedAnchor(of: window.frame, anchor: .bottomCenter, in: visibleFrame)
        let frame = WidgetPlacement.frame(size: size, anchor: .bottomCenter, at: anchor, in: visibleFrame)
        window.setFrame(frame, display: true)
        positionQueue()
        onWidgetsChanged?()
    }

    // MARK: Queue panel

    /// The queue beside the player when there is room for it (on screen,
    /// off the other widgets), else as a page above the search field.
    private func updateQueue() {
        guard model.isQueueOpen, let player = windows[.player] else {
            closeQueue()
            if model.queueAsPage { model.queueAsPage = false }
            return
        }
        guard let frame = sideQueueFrame(besides: player.frame) else {
            closeQueue()
            if !model.queueAsPage { model.queueAsPage = true }
            return
        }
        if model.queueAsPage { model.queueAsPage = false }
        if queueWindow == nil {
            let window = DesktopWidgetWindow(widget: nil, frame: frame)
            window.contentView = DesktopHostingView(rootView: AnyView(
                WidgetRoot(settings: settings) { QueuePanel(model: self.model) }.environment(\.coverImages, model.images)
            ))
            queueWindow = window
            player.addChildWindow(window, ordered: .above)
            window.orderFrontRegardless()
        }
        if queueWindow?.frame != frame { queueWindow?.setFrame(frame, display: true) }
    }

    /// Keeps an open side panel beside the player after a resize; when it
    /// no longer fits there, the queue becomes a page.
    private func positionQueue() {
        guard let queueWindow, let player = windows[.player] else { return }
        guard let frame = sideQueueFrame(besides: player.frame) else {
            updateQueue()
            return
        }
        if queueWindow.frame != frame { queueWindow.setFrame(frame, display: true) }
    }

    private func sideQueueFrame(besides player: CGRect) -> CGRect? {
        let height = max(Self.queueMinimumHeight, player.height)
        let others = windows.filter { $0.key != .player }.map(\.value.frame)
        return PlayerLayout.queueFrame(besides: player, height: height, in: visibleFrame, avoiding: others)
    }

    private func closeQueue() {
        guard let window = queueWindow else { return }
        queueWindow = nil
        window.parent?.removeChildWindow(window)
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        releaseClosedWindows()
    }

    // MARK: Keyboard and visibility

    /// The search button or "Add Songs": the player's window takes the
    /// keyboard (without making Ahenk the active app).
    private func focusSearch() {
        guard let window = windows[.player] else { return }
        window.makeKey()
    }

    private func clockVisibilityChanged() {
        guard let window = windows[.clock] else {
            clock.pause()
            return
        }
        if window.occlusionState.contains(.visible) {
            clock.resume()
        } else {
            clock.pause()
        }
    }
}

/// A widget window's content in the app's language (dates, upper case).
private struct WidgetRoot<Content: View>: View {
    let settings: AppSettings
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .environment(\.locale, settings.general.language.locale())
    }
}

/// The clock reading the live settings (size, date, format).
private struct ClockRoot: View {
    let clock: ClockModel
    let model: DesktopPlayerModel
    let settings: AppSettings

    var body: some View {
        ClockWidget(clock: clock, model: model, settings: settings.player)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
