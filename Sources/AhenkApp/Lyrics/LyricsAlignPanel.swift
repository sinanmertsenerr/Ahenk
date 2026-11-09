import AhenkKit
import SwiftUI

/// "Align Lyrics" over the lines (Beta): the words on the left, and on the
/// right what Ahenk needs, the button, and how far the work is.
struct LyricsAlignPanel: View {
    @Bindable var aligner: LyricsAlignmentController
    let lyrics: LyricsController
    let theme: PlayerTheme
    @FocusState private var isEditing: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            editor
            VStack(alignment: .leading, spacing: 8) {
                switch aligner.stage {
                case .idle:
                    idle(problem: nil)
                case .failed(let message):
                    idle(problem: message)
                case .listening(let collected, let wanted):
                    progress(
                        title: "Listening to the song…".l10n, value: wanted > 0 ? collected / wanted : 0,
                        detail: L10n.format("%1$@ of %2$@", DurationText.string(collected), DurationText.string(wanted))
                    )
                    HStack(spacing: 8) {
                        if !aligner.isDemo {
                            CapsuleButton(title: "Align Now".l10n, symbol: "wand.and.stars", filled: aligner.canFinishListening, accent: theme.accent) {
                                aligner.finishListening()
                            }
                            .disabled(!aligner.canFinishListening)
                            .opacity(aligner.canFinishListening ? 1 : 0.5)
                        }
                        CapsuleButton(title: "Cancel".l10n, symbol: "xmark") { aligner.cancel() }
                    }
                case .reading:
                    progress(title: "Reading the song file…".l10n, value: nil, detail: nil)
                    CapsuleButton(title: "Cancel".l10n, symbol: "xmark") { aligner.cancel() }
                case .recognizing(let done):
                    progress(title: "Recognising the words…".l10n, value: done, detail: ValueFormat.percent(done))
                    CapsuleButton(title: "Cancel".l10n, symbol: "xmark") { aligner.cancel() }
                case .done(let lines, let total, let isRough):
                    Label(L10n.format("Timed %1$d of %2$d lines.", lines, total), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    if isRough {
                        note("Some lines were not heard clearly; they are placed between the others.".l10n)
                    }
                    if aligner.isDemo {
                        note("Demo: the timing comes from the demo song itself.".l10n)
                    }
                    CapsuleButton(title: "Done".l10n, symbol: "checkmark", filled: true, accent: theme.accent) {
                        aligner.show(.idle)
                        lyrics.panel = nil
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(width: 252, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            aligner.prepare()
            isEditing = aligner.text.isEmpty
        }
    }

    // MARK: The words

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $aligner.text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .focused($isEditing)
                .disabled(aligner.isBusy)
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
                .onExitCommand { lyrics.panel = nil }
                .accessibilityLabel("The song's words".l10n)
            if aligner.text.isEmpty {
                Text("Paste or type the song's words here, one line under the other.".l10n)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.accent.opacity(isEditing ? 0.5 : 0), lineWidth: 1))
    }

    // MARK: Before the work

    @ViewBuilder
    private func idle(problem: String?) -> some View {
        if let problem {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color(red: 1, green: 0.78, blue: 0.35))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            note("Ahenk recognises the sung words on this Mac and gives every line its time. Nothing leaves this Mac.".l10n)
        }
        if aligner.isDemo {
            note("Demo: the timing comes from the demo song itself.".l10n)
        } else {
            tools
        }
        if problem == nil, aligner.listensToTheSong, aligner.tools.isReady {
            note("Ahenk listens to the rest of the song first. Start the song over to time every line.".l10n)
        }
        CapsuleButton(title: "Align to the Song".l10n, symbol: "wand.and.stars", filled: aligner.canStart, accent: theme.accent) {
            aligner.start()
        }
        .disabled(!aligner.canStart)
        .opacity(aligner.canStart ? 1 : 0.5)
    }

    /// The tool and the model: found, or what to do about it.
    @ViewBuilder
    private var tools: some View {
        if aligner.tools.isReady, let model = aligner.tools.model {
            Label(L10n.format("Ready: %@", model.deletingPathExtension().lastPathComponent), systemImage: "checkmark.circle.fill")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        if aligner.tools.executable == nil {
            note("whisper-cli was not found. Install it with Homebrew (brew install whisper-cpp) or choose it yourself.".l10n)
            HStack(spacing: 6) {
                CapsuleButton(title: "Copy the Command".l10n, symbol: "doc.on.doc") { aligner.copyInstallCommand() }
                CapsuleButton(title: "Choose…".l10n, symbol: "folder") { aligner.chooseExecutable() }
            }
        } else if aligner.tools.model == nil {
            switch aligner.download {
            case .running(let done):
                progress(title: "Downloading the model…".l10n, value: done, detail: ValueFormat.percent(done))
                CapsuleButton(title: "Cancel".l10n, symbol: "xmark") { aligner.cancelDownload() }
            case .none, .failed:
                note(aligner.download == .failed
                    ? "The model could not be downloaded.".l10n
                    : "No speech model was found. Download one (574 MB, once) or choose a model file.".l10n)
                HStack(spacing: 6) {
                    CapsuleButton(title: "Download the Model".l10n, symbol: "arrow.down.circle") { aligner.downloadModel() }
                    CapsuleButton(title: "Choose…".l10n, symbol: "folder") { aligner.chooseModel() }
                }
            }
        }
    }

    // MARK: Pieces

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.66))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func progress(title: String, value: Double?, detail: String?) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Spacer(minLength: 4)
            if let detail {
                Text(detail)
                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        if let value {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    Capsule().fill(theme.accent).frame(width: max(4, proxy.size.width * min(1, max(0, value))))
                }
            }
            .frame(height: 4)
            .animation(.easeOut(duration: 0.25), value: value)
            .accessibilityHidden(true)
        } else {
            ProgressView().controlSize(.small).tint(.white)
        }
    }
}

/// "Beta" beside the panel's title.
struct BetaBadge: View {
    var body: some View {
        Text("Beta".l10n)
            .font(.system(size: 9.5, weight: .bold))
            .textCase(.uppercase)
            .kerning(0.5)
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(.white.opacity(0.16)))
            .accessibilityLabel("Beta".l10n)
    }
}
