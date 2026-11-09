import AhenkKit
import AppKit
import SwiftUI

/// The search field: searches the catalog for the source songs play in
/// ("Search Apple Music"). Only this field takes the keyboard, and only
/// when it is clicked (or the search button asks for it); Esc empties it
/// and gives the keyboard back.
struct SearchField: View {
    @Bindable var model: DesktopPlayerModel
    var showsClose = false
    @FocusState private var isFocused: Bool
    /// `.key` only while the window takes the keyboard.
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        let theme = model.theme
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            TextField(text: $model.query, prompt: Text(model.searchPrompt).foregroundStyle(.white.opacity(0.48))) {
                Text(model.searchPrompt)
            }
            .textFieldStyle(.plain)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white)
            .focused($isFocused)
            .onSubmit { model.submitSearch() }
            .onExitCommand { model.clearSearch() }
            if model.search.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                    .transition(.opacity)
            }
            if !model.query.isEmpty || showsClose {
                Button {
                    model.clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.55))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(model.query.isEmpty ? "Close Search".l10n : "Clear Search".l10n)
                .accessibilityLabel(model.query.isEmpty ? "Close Search".l10n : "Clear Search".l10n)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 15)
        .frame(height: PlayerLayout.searchHeight)
        .widgetGlass(Capsule(), tint: theme.glass)
        .overlay {
            Capsule()
                .strokeBorder(theme.accent.opacity(isTyping ? 0.6 : 0), lineWidth: 1)
                .animation(.easeOut(duration: 0.15), value: isTyping)
        }
        .animation(.easeOut(duration: 0.15), value: model.search.isLoading)
        .animation(.easeOut(duration: 0.15), value: model.query.isEmpty)
        .onChange(of: model.focusRequest) {
            isFocused = true
        }
        .onAppear {
            if model.isSearchOpen, model.size == .small { isFocused = true }
        }
    }
}

extension SearchField {
    /// The field has the keyboard: focused in the key window.
    private var isTyping: Bool { isFocused && activeState == .key }
}

/// A round glass button beside the field or above the small bar.
struct RoundGlassButton: View {
    let symbol: String
    let help: String
    let tint: Color
    var isOn = false
    var accent: Color = .white
    let action: () -> Void

    var body: some View {
        WidgetIconButton(symbol: symbol, pointSize: 13, side: 34, isOn: isOn, accent: accent, help: help, action: action)
            .widgetGlass(Circle(), tint: tint)
    }
}
