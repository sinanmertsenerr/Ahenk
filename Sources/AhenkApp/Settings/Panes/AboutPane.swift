import AhenkKit
import SwiftUI

struct AboutPane: View {
    @State private var showsNotices = false

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            AppMark()
                .frame(width: 96, height: 96)
            VStack(spacing: 4) {
                Text("Ahenk")
                    .font(.largeTitle.weight(.semibold))
                Text(L10n.format("Version %@ (%@)", AppInfo.version, AppInfo.build))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text("Your desktop, in time with the music.".l10n)
                .font(.title3)
            HStack(spacing: 10) {
                Button("Source Code".l10n) {
                    NSWorkspace.shared.open(AppInfo.repositoryURL)
                }
                Button("Third-Party Notices".l10n) {
                    showsNotices = true
                }
            }
            .padding(.top, 6)
            Spacer(minLength: 0)
            Text("© 2026 Sinan Mert Sener · MIT License".l10n)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showsNotices) {
            NoticesSheet()
        }
    }
}

/// The app's mark: a glowing ring around a soft gradient disc.
struct AppMark: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(
                    AngularGradient(
                        colors: [.pink, .orange, .yellow, .mint, .cyan, .indigo, .purple, .pink],
                        center: .center
                    )
                )
                .blur(radius: 6)
                .opacity(0.8)
            Circle()
                .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.05)], startPoint: .top, endPoint: .bottom))
                .padding(7)
            Image(systemName: "waveform")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(colors: [.pink, .orange], startPoint: .leading, endPoint: .trailing)
                )
        }
        .accessibilityHidden(true)
    }
}

/// Licences of the bundled third-party code.
struct NoticesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Third-Party Notices".l10n)
                .font(.title2.weight(.semibold))
            ScrollView {
                Text(Self.text)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 280)
            HStack {
                Spacer()
                Button("Done".l10n) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 440)
    }

    /// THIRD_PARTY_NOTICES.md, copied into the app by make-app.sh.
    static var text: String {
        guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "mediaremote-adapter, BSD 3-Clause License, Copyright (c) 2025 Jonas van den Berg and contributors." }
        return text
    }
}
