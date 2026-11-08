import Foundation

/// Locates the SwiftPM resource bundle (`Ahenk_AhenkApp.bundle`: Turkish
/// strings, shaders, later fonts).
///
/// NEVER use `Bundle.module`: SwiftPM's generated accessor calls fatalError
/// when the bundle is not where it expects (a moved or re-packaged app), and
/// since the Settings window resolves every string at once that reads as
/// "Ahenk crashes the moment Settings opens". A missing bundle must degrade
/// (English text, no shader), never crash.
enum ResourceBundle {
    static let name = "Ahenk_AhenkApp.bundle"

    static let bundle: Bundle? = {
        let candidates: [URL?] = [
            Bundle.main.resourceURL,                                // packaged .app
            Bundle.main.executableURL?.deletingLastPathComponent(), // `swift run`
            Bundle.main.bundleURL,
        ]
        for base in candidates {
            guard let url = base?.appendingPathComponent(name),
                  let bundle = Bundle(url: url)
            else { continue }
            return bundle
        }
        return nil
    }()

    static func url(forResource name: String, withExtension ext: String, subdirectory: String? = nil) -> URL? {
        bundle?.url(forResource: name, withExtension: ext, subdirectory: subdirectory)
    }
}
