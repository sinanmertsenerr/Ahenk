import AhenkKit
import AppKit

/// `--demo-local`: a folder of generated tones (invented titles, generated
/// covers) in a temporary directory, dropped on the desktop player like a
/// user's folder and played by Ahenk's own player, muted. The Local source
/// can then be seen on the desktop and measured without any real music;
/// the folder is deleted when Ahenk quits.
@MainActor
enum LocalDemo {
    private static var root: URL?
    private static let log = AhenkLogger(category: "local")

    static func start(environment: AppEnvironment) async {
        guard environment.demo != nil, root == nil else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ahenk-demo-songs-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("Demo Tones", isDirectory: true)
        self.root = root
        let palettes = DemoCatalog.songs.map(\.palette)
        do {
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let songs: [(String, Double, Double)] = [("Generated One", 330, 120), ("Generated Two", 392, 100), ("Generated Three", 262, 140)]
                for (index, song) in songs.enumerated() {
                    let cover = DemoArtwork.makeImage(palette: palettes[index % palettes.count], seed: UInt64(40 + index), pixelSize: 600)
                        .flatMap(StickerCutter.pngData)
                    if index == 0, let cover {
                        // The folder's picture covers the songs without one of their own.
                        try cover.write(to: folder.appendingPathComponent("cover.png"))
                    }
                    try await GeneratedSongFiles.writeM4A(
                        GeneratedSongFiles.tone(seconds: 50, sampleRate: 44_100, bpm: song.2, frequency: song.1), sampleRate: 44_100,
                        to: folder.appendingPathComponent("0\(index + 1) \(song.0).m4a"),
                        title: song.0, artist: "Ahenk Tones", album: "Demo Tones", trackNumber: index + 1, artwork: index == 1 ? cover : nil
                    )
                }
            }.value
        } catch {
            log.error("The demo's song files could not be written: \(error)")
            return
        }
        // The demo's own player steps back; Ahenk's player takes over.
        await environment.demo?.perform(.pause)
        environment.desktopPlayer.model.playDropped([folder])
        log.notice("Demo: playing generated tones from a temporary folder, muted")
    }

    static func cleanUp() {
        guard let root else { return }
        try? FileManager.default.removeItem(at: root)
        self.root = nil
    }
}
