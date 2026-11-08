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
}

/// The app's one edge light renderer (device, queue, compiled shader,
/// pipelines), shared by the screens' light and the Settings previews.
/// Compiled once, off the main thread, the first time anything asks.
@MainActor
final class EdgeLightShader {
    static let shared = EdgeLightShader()

    enum State {
        case idle
        case loading
        case ready(EdgeLightRenderer)
        case failed(String)
    }

    private(set) var state: State = .idle
    private var waiters: [(EdgeLightRenderer?) -> Void] = []
    private static let log = AhenkLogger(category: "light")

    /// The renderer once compiled; `nil` while compiling or after a failure.
    var renderer: EdgeLightRenderer? {
        if case .ready(let renderer) = state { return renderer }
        return nil
    }

    /// Calls `completion` on the main thread with the renderer (compiling it
    /// first if needed), or `nil` when the shader cannot be compiled.
    func load(_ completion: @escaping (EdgeLightRenderer?) -> Void) {
        switch state {
        case .ready(let renderer):
            completion(renderer)
        case .failed:
            completion(nil)
        case .loading:
            waiters.append(completion)
        case .idle:
            state = .loading
            waiters.append(completion)
            Task.detached(priority: .userInitiated) {
                let result = Result { try EdgeLightRenderer(source: MetalShaders.source(named: "EdgeLight")) }
                await MainActor.run { EdgeLightShader.shared.finish(result) }
            }
        }
    }

    private func finish(_ result: Result<EdgeLightRenderer, Error>) {
        let renderer: EdgeLightRenderer?
        switch result {
        case .success(let compiled):
            state = .ready(compiled)
            renderer = compiled
            Self.log.info("Edge light shader compiled in \(Int(compiled.compileMilliseconds.rounded())) ms on \(compiled.device.name)")
        case .failure(let error):
            state = .failed(String(describing: error))
            renderer = nil
            Self.log.error("Edge light shader unavailable: \(error)")
        }
        let waiting = waiters
        waiters = []
        waiting.forEach { $0(renderer) }
    }
}
