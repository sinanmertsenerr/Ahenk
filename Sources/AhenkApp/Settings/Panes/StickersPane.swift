import AhenkKit
import SwiftUI

struct StickersPane: View {
    @Bindable var settings: AppSettings

    var body: some View {
        PaneForm(
            pane: .stickers,
            summary: "Pick any photo and Ahenk cuts out the subject, ready to stick on the desktop, the clock or the player.".l10n
        ) {
            Section {
                ToggleRow(title: "Show stickers".l10n, isOn: $settings.stickers.enabled)
                ToggleRow(title: "White border".l10n, isOn: $settings.stickers.border)
            }

            Section("Your Stickers".l10n) {
                EmptyRow(text: "No stickers yet.".l10n)
            }
        }
    }
}
