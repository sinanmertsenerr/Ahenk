import AhenkKit
import AppKit
import SwiftUI

/// The queue beside the player (when there is room for it): what plays,
/// what is up next (play any of it, remove it), and a way to add more.
/// Ahenk keeps this queue itself; the music apps do not share theirs. While
/// Ahenk's queue is not playing, a music site's own queue shows instead.
struct QueuePanel: View {
    let model: DesktopPlayerModel

    var body: some View {
        let theme = model.theme
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Queue".l10n)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                    Text(QueueList.contextText(model))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                WidgetIconButton(symbol: "xmark", pointSize: 11.5, side: 28, help: "Hide the Queue".l10n) {
                    model.isQueueOpen = false
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .padding(.top, 12)
            .padding(.bottom, 10)
            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(height: 0.5)
                .padding(.horizontal, 14)
            QueueList(model: model, showsContext: false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetGlass(RoundedRectangle(cornerRadius: 26, style: .continuous), tint: theme.glass)
        .environment(\.colorScheme, .dark)
        .padding(PlayerLayout.margin)
    }
}

/// The queue's songs and "Add Songs", in the side panel or as a page.
struct QueueList: View {
    let model: DesktopPlayerModel
    /// The page has no header of its own for "Album: …".
    let showsContext: Bool

    var body: some View {
        let theme = model.theme
        let conductor = model.conductor
        let queue = conductor.queue
        VStack(spacing: 0) {
            if conductor.isActive, let current = queue.current {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 8) {
                        if showsContext {
                            Text(Self.contextText(model))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                        }
                        WidgetSectionTitle(title: "Now Playing".l10n)
                        QueueRow(model: model, entry: current, isCurrent: true)
                        HStack {
                            WidgetSectionTitle(title: "Up Next".l10n)
                            if !queue.upNext.isEmpty {
                                Button("Clear".l10n) { conductor.clearUpNext() }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(theme.accent)
                                    .help("Removes every song that is up next.".l10n)
                            }
                        }
                        .padding(.top, 6)
                        if queue.upNext.isEmpty {
                            Text(queue.repeatMode == .all ? "The queue starts over after this song.".l10n : "Nothing is up next.".l10n)
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.55))
                                .padding(.vertical, 6)
                        } else {
                            LazyVStack(spacing: 1) {
                                ForEach(queue.upNext) { entry in
                                    QueueRow(model: model, entry: entry, isCurrent: false)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .scrollIndicators(.never)
                .fadesScrollEdges()
            } else if let siteQueue = model.siteQueue, !siteQueue.items.isEmpty {
                SiteQueueList(model: model, queue: siteQueue, showsContext: showsContext)
            } else {
                WidgetMessage(
                    symbol: "list.bullet",
                    text: "Nothing is queued. Start an album or a list here, or add songs with Play Next and Add to Queue.".l10n
                )
            }
            HStack {
                CapsuleButton(title: "Add Songs".l10n, symbol: "plus") {
                    model.requestSearchFocus()
                }
                .help("Search for songs to add.".l10n)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            .padding(.top, 6)
        }
        .animation(.smooth(duration: 0.22), value: queue.entries.map(\.id))
    }

    @MainActor
    static func contextText(_ model: DesktopPlayerModel) -> String {
        if !model.conductor.isActive, let siteQueue = model.siteQueue, !siteQueue.items.isEmpty {
            return L10n.format("The queue on %@", siteQueue.site.title)
        }
        guard model.conductor.isActive, let context = model.conductor.queue.context else {
            return "Songs started from the player".l10n
        }
        switch context {
        case .album(_, let title): return L10n.format("Album: %@", title)
        case .playlist(_, let name): return L10n.format("Playlist: %@", name)
        case .artist(_, let name): return L10n.format("Artist: %@", name)
        case .continuePlaying: return "From Continue Playing".l10n
        case .search: return "From search".l10n
        }
    }
}

/// One queued song: plays when clicked; the minus removes it.
private struct QueueRow: View {
    let model: DesktopPlayerModel
    let entry: QueueEntry
    let isCurrent: Bool
    @State private var isHovering = false

    var body: some View {
        let theme = model.theme
        HStack(spacing: 4) {
            Button {
                model.conductor.jump(to: entry.id, in: model.listeningSource)
            } label: {
                HStack(spacing: 10) {
                    CoverArt(song: entry.song, side: 34, cornerRadius: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.song.title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(entry.song.artistName)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.58))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    if isCurrent {
                        EqualizerBars(isPlaying: model.isPlaying, color: theme.accent)
                            .frame(width: 14, height: 12)
                            .padding(.trailing, 6)
                    } else if entry.isUserAdded {
                        Image(systemName: "text.append")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.4))
                            .help("Added by you".l10n)
                    }
                }
                .padding(.leading, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The playing song is not a button, but it is not dimmed either.
            .allowsHitTesting(!isCurrent)
            .help(isCurrent ? "" : "Play Now".l10n)

            if !isCurrent {
                Button {
                    model.conductor.remove(entry.id)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(isHovering ? 0.75 : 0.32))
                        .frame(width: 26, height: 26)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Remove from the Queue".l10n)
                .accessibilityLabel("Remove from the Queue".l10n)
            }
        }
        .padding(.trailing, 4)
        .rowHighlight(isPlaying: isCurrent, accent: theme.accent, cornerRadius: 11)
        .onHover { isHovering = $0 }
        .contextMenu {
            if !isCurrent {
                Button("Play Now".l10n, systemImage: "play.fill") { model.conductor.jump(to: entry.id, in: model.listeningSource) }
                Button("Play Next".l10n, systemImage: "text.line.first.and.arrowtriangle.forward") { model.conductor.moveToFront(entry.id) }
                Button("Remove from the Queue".l10n, systemImage: "minus.circle") { model.conductor.remove(entry.id) }
            }
        }
    }
}

/// A music site's own queue: what plays there and what comes next (play any
/// of it; remove it where the site allows).
private struct SiteQueueList: View {
    let model: DesktopPlayerModel
    let queue: BrowserQueue
    let showsContext: Bool

    var body: some View {
        let current = queue.items.first(where: \.isCurrent)
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 8) {
                if showsContext {
                    Text(QueueList.contextText(model))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                if let current {
                    WidgetSectionTitle(title: "Now Playing".l10n)
                    SiteQueueRow(model: model, item: current, canRemove: false)
                }
                WidgetSectionTitle(title: "Up Next".l10n)
                    .padding(.top, current == nil ? 0 : 6)
                if queue.upNext.isEmpty {
                    Text("Nothing is up next.".l10n)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.vertical, 6)
                } else {
                    LazyVStack(spacing: 1) {
                        ForEach(queue.upNext) { item in
                            SiteQueueRow(model: model, item: item, canRemove: queue.canRemove)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.never)
        .fadesScrollEdges()
    }
}

private struct SiteQueueRow: View {
    let model: DesktopPlayerModel
    let item: BrowserQueue.Item
    let canRemove: Bool
    @State private var isHovering = false

    var body: some View {
        let theme = model.theme
        HStack(spacing: 4) {
            Button {
                model.playSiteQueueItem(item)
            } label: {
                HStack(spacing: 10) {
                    CoverArt(song: item.song, side: 34, cornerRadius: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.song.title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(item.song.artistName)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.58))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    if item.isCurrent {
                        EqualizerBars(isPlaying: model.isPlaying, color: theme.accent)
                            .frame(width: 14, height: 12)
                            .padding(.trailing, 6)
                    }
                }
                .padding(.leading, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .allowsHitTesting(!item.isCurrent)
            .help(item.isCurrent ? "" : "Play Now".l10n)

            if canRemove, !item.isCurrent {
                Button {
                    model.removeSiteQueueItem(item)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(isHovering ? 0.75 : 0.32))
                        .frame(width: 26, height: 26)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Remove from the Queue".l10n)
                .accessibilityLabel("Remove from the Queue".l10n)
            }
        }
        .padding(.trailing, 4)
        .rowHighlight(isPlaying: item.isCurrent, accent: theme.accent, cornerRadius: 11)
        .onHover { isHovering = $0 }
    }
}
