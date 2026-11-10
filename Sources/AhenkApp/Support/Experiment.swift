import Foundation

/// Measurement switches for performance runs, off unless named at launch:
/// `open Ahenk.app --args -AhenkExperiment lightFrozen,videoPaused`.
enum Experiment {
    private static let names: Set<Substring> = Set((UserDefaults.standard.string(forKey: "AhenkExperiment") ?? "").split(separator: ","))

    static func has(_ name: String) -> Bool { names.contains(Substring(name)) }
}
