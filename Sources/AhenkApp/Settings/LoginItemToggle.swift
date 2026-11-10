import AhenkKit
import SwiftUI

/// "Open Ahenk at login", as macOS has it (General pane and the guide).
struct LoginItemToggle: View {
    let loginItem: LoginItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding { loginItem.isOn } set: { loginItem.set($0) }) {
                Text("Open Ahenk at login".l10n)
                Text(detail)
            }
            .disabled(!loginItem.canChange || loginItem.state == .unavailable)
            if loginItem.state == .needsApproval, loginItem.canChange {
                HStack {
                    Text("Ahenk is switched off in System Settings › General › Login Items.".l10n)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Login Items…".l10n) { loginItem.openSystemSettings() }
                        .controlSize(.small)
                }
            }
            if let problem = loginItem.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { loginItem.refresh() }
    }

    private var detail: String {
        if !loginItem.canChange { return "Not changed in demo mode.".l10n }
        switch loginItem.state {
        case .on: return "Ahenk starts in the menu bar when you log in, without opening a window.".l10n
        case .off: return "Ahenk starts only when you open it.".l10n
        case .needsApproval: return "Waiting for your approval in System Settings.".l10n
        case .unavailable: return "Only the Ahenk app can open at login.".l10n
        }
    }
}
