import AhenkKit
import Foundation
import Metal

/// Loads `.metal` sources from the resource bundle and compiles them at
/// runtime.
///
/// Why runtime compilation: SwiftPM has no Metal build step, and
/// precompiling in make-app.sh needs Xcode's separately downloaded Metal
/// toolchain (`xcodebuild -downloadComponent MetalToolchain`), which this
/// machine and fresh installs may not have. Compiling the source takes tens
/// of milliseconds, once per launch; `swift run` and the packaged app behave
/// the same.
enum MetalShaders {
    enum LoadError: Error, CustomStringConvertible {
        case missingSource(String)

        var description: String {
            switch self {
            case .missingSource(let name): "Shader source \(name).metal is not in the resource bundle"
            }
        }
    }

    static func sourceURL(named name: String) -> URL? {
        ResourceBundle.url(forResource: name, withExtension: "metal", subdirectory: "Shaders")
    }

    static func source(named name: String) throws -> String {
        guard let url = sourceURL(named: name) else { throw LoadError.missingSource(name) }
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func makeLibrary(named name: String, device: MTLDevice) throws -> MTLLibrary {
        let options = MTLCompileOptions()
        options.languageVersion = .version3_0
        return try device.makeLibrary(source: source(named: name), options: options)
    }
}
