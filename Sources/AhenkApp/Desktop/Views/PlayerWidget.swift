import AhenkKit
import AppKit
import SwiftUI

/// The player window's content, stacked from the bottom (where the window
/// is anchored): the bar, the search field, then the albums or an open
/// page, and the live wallpaper's dots on top. The large player always
/// shows the field and the albums; the small one is its bar with round
/// buttons above, and grows a field and a page only on request.
struct PlayerWidget: View {
    let model: DesktopPlayerModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let state = model.layoutState
        let theme = model.theme
        VStack(spacing: PlayerLayout.spacing) {
            Spacer(minLength: 0)
            if state.showsWallpaperPicker {
                WallpaperPicker(model: model)
            }
            switch state.size {
            case .large:
                largeTop(state: state, theme: theme)
            case .small:
                if state.showsPage {
                    PageArea(model: model)
                        .transition(pageTransition)
                }
                smallAccessories(theme: theme)
            }
            if state.hasSearch {
                searchRow(state: state, theme: theme)
                    .transition(.opacity.combined(with: .offset(y: 8)))
            }
            if state.hasBar {
                PlayerBar(model: model)
            }
        }
        .frame(width: PlayerLayout.width(state))
        .padding(PlayerLayout.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .environment(\.colorScheme, .dark)
        .environment(\.coverImages, model.images)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.28), value: state)
        .animation(.smooth(duration: 0.25), value: model.status)
    }

    private var pageTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97, anchor: .bottom))
    }

    // MARK: Large

    @ViewBuilder
    private func largeTop(state: PlayerLayoutState, theme: PlayerTheme) -> some View {
        if state.showsPage {
            PageArea(model: model)
                .transition(pageTransition)
        } else if state.showsAlbums {
            CoverFlowView(model: model)
                .frame(height: PlayerLayout.albumsHeight)
                .overlay(alignment: .top) { statusArea(theme: theme) }
                .transition(.opacity)
        } else {
            statusArea(theme: theme)
                .frame(height: PlayerLayout.accessoryHeight)
        }
    }

    private func searchRow(state: PlayerLayoutState, theme: PlayerTheme) -> some View {
        HStack(spacing: 8) {
            SearchField(model: model, showsClose: state.size == .small)
            if state.size == .large {
                if model.canClearDesk {
                    ClearDeskButton(isOn: model.isDeskCleared, tint: theme.glass, accent: theme.accent) { model.toggleClearDesk() }
                }
                lockButton(theme: theme)
                RoundGlassButton(symbol: "arrow.down.right.and.arrow.up.left", help: "Small Player".l10n, tint: theme.glass) {
                    model.setSize(.small)
                }
            }
        }
    }

    // MARK: Small

    private func smallAccessories(theme: PlayerTheme) -> some View {
        HStack(spacing: 8) {
            statusArea(theme: theme)
            Spacer(minLength: 0)
            if !model.isSearchOpen, model.settings.player.showSearch {
                RoundGlassButton(symbol: "magnifyingglass", help: "Search".l10n, tint: theme.glass) {
                    model.requestSearchFocus()
                }
            }
            if model.canClearDesk {
                ClearDeskButton(isOn: model.isDeskCleared, tint: theme.glass, accent: theme.accent) { model.toggleClearDesk() }
            }
            lockButton(theme: theme)
            RoundGlassButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Large Player".l10n, tint: theme.glass) {
                model.setSize(.large)
            }
        }
        .frame(height: PlayerLayout.accessoryHeight)
    }

    /// Locks the widgets in place, so clicks beside their buttons reach
    /// the files behind them (also in the menu bar menu).
    private func lockButton(theme: PlayerTheme) -> some View {
        let isLocked = model.settings.player.widgetsLocked
        return RoundGlassButton(
            symbol: isLocked ? "lock.fill" : "lock.open", help: isLocked ? "Unlock Widgets".l10n : "Lock Widgets".l10n,
            tint: theme.glass, isOn: isLocked, accent: theme.accent
        ) {
            model.settings.player.widgetsLocked.toggle()
        }
    }

    @ViewBuilder
    private func statusArea(theme: PlayerTheme) -> some View {
        if let conflict = model.services.state.conflict {
            // Two sources play at once: the question is asked here, where
            // the music is, as well as in the menu bar menu.
            ConflictQuestion(conflict: conflict, services: model.services, tint: theme.glass)
                .transition(.opacity.combined(with: .offset(y: 6)))
        } else if let status = model.status {
            StatusToast(status: status, tint: theme.glass) { model.clearStatus() }
                .id(status.id)
                .transition(.opacity.combined(with: .offset(y: 6)))
        }
    }
}
