import AhenkKit
import SwiftUI
import UniformTypeIdentifiers

struct StickersPane: View {
    @Bindable var settings: AppSettings
    let stickers: StickerController
    @State private var isDropTargeted = false

    var body: some View {
        PaneForm(
            pane: .stickers,
            summary: "Pick any photo and Ahenk cuts out the subject, ready to stick on the desktop, the clock or the player.".l10n
        ) {
            Section {
                ToggleRow(title: "Show stickers".l10n, isOn: $settings.stickers.enabled)
                ToggleRow(title: "White border".l10n, isOn: $settings.stickers.border)
            } footer: {
                Text("The subject is cut out on this Mac; photos and stickers never leave it.".l10n)
            }

            Section {
                if stickers.stickers.isEmpty {
                    EmptyRow(text: "No stickers yet.".l10n)
                } else {
                    ForEach(stickers.stickers.reversed()) { sticker in
                        StickerRow(sticker: sticker, stickers: stickers)
                    }
                }
                LabeledContent {
                    HStack(spacing: 8) {
                        if stickers.isCutting {
                            ProgressView().controlSize(.small)
                        }
                        Button("Add Sticker…".l10n) { stickers.pickPhotos() }
                    }
                } label: {
                    Text(isDropTargeted ? "Drop to make stickers".l10n : "Drop photos here, or on the clock, the list or the player.".l10n)
                        .foregroundStyle(isDropTargeted ? .primary : .secondary)
                }
                if let problem = stickers.problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Your Stickers".l10n)
            } footer: {
                Text("Drag a sticker to move it, its corner to resize it and the handle above it to turn it; right-click it to stick it to the clock, the list or the player, or to remove it.".l10n)
            }
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url, FileKinds.isPicture(url) else { return }
                        Task { @MainActor in await stickers.add(photoAt: url) }
                    }
                }
                return !providers.isEmpty
            }
        }
    }
}

/// One sticker: its picture, its name, where it is, and a delete button.
private struct StickerRow: View {
    let sticker: Sticker
    let stickers: StickerController

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let image = stickers.thumbnail(for: sticker.id) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(sticker.name.isEmpty ? "Sticker".l10n : sticker.name)
                    .lineLimit(1)
                Text(StickerController.placeText(sticker.placement))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if sticker.placement.widget != nil {
                Button("Leave on the Desktop".l10n) { stickers.attach(sticker.id, to: nil) }
                    .controlSize(.small)
            }
            Button {
                stickers.remove(sticker.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove Sticker".l10n)
            .accessibilityLabel("Remove Sticker".l10n)
        }
    }
}
