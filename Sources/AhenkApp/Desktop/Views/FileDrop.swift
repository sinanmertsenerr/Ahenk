import AhenkKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What kind of file the user dropped or picked.
enum FileKinds {
    static func isPicture(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    static func isSong(_ url: URL) -> Bool {
        LocalLibraryScanner.audioExtensions.contains(url.pathExtension.lowercased())
    }
}

/// Lets a widget take files dragged onto it (pictures become stickers
/// there; folders and songs play on the list and the player). The drop
/// point goes along in screen coordinates.
private struct FileDropModifier: ViewModifier {
    let model: DesktopPlayerModel
    let widget: DesktopWidget
    @Binding var isTargeted: Bool
    @Environment(\.widgetMover) private var mover

    func body(content: Content) -> some View {
        content.onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers, location in
            let frame = mover?.window?.frame
            let point = frame.map { CGPoint(x: $0.minX + location.x, y: $0.maxY - location.y) }
            let found = FileDropCollector(count: providers.count) { urls in
                _ = model.onDropFiles?(urls, widget, point)
            }
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    DispatchQueue.main.async { found.add(url) }
                }
            }
            return !providers.isEmpty
        }
    }
}

/// Gathers the URLs of one drop, then hands them over together.
@MainActor
private final class FileDropCollector {
    private var urls: [URL] = []
    private var left: Int
    private let done: ([URL]) -> Void

    init(count: Int, done: @escaping ([URL]) -> Void) {
        left = count
        self.done = done
    }

    func add(_ url: URL?) {
        if let url, url.isFileURL { urls.append(url) }
        left -= 1
        if left == 0 { done(urls) }
    }
}

extension View {
    func acceptsFileDrops(model: DesktopPlayerModel, widget: DesktopWidget, isTargeted: Binding<Bool> = .constant(false)) -> some View {
        modifier(FileDropModifier(model: model, widget: widget, isTargeted: isTargeted))
    }
}
