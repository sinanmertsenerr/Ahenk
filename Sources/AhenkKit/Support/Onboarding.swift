import Foundation

/// The pages of the first-run guide, in order: what Ahenk is, the system
/// audio permission, Automation for the music apps, the browser extension,
/// and the last touches (open at login).
public enum OnboardingPage: String, CaseIterable, Sendable {
    case welcome
    case listening
    case musicApps
    case browser
    case finish

    public var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    public var next: OnboardingPage? {
        let pages = Self.allCases
        return index + 1 < pages.count ? pages[index + 1] : nil
    }

    public var previous: OnboardingPage? {
        index > 0 ? Self.allCases[index - 1] : nil
    }
}

/// When the guide opens by itself.
public enum OnboardingPolicy {
    /// The first normal launch shows the guide until it was closed once;
    /// `requested` (`--welcome`) shows it in a normal or demo run. Smoke
    /// runs never show a window.
    public static func showsAtLaunch(mode: LaunchOptions.Mode, completed: Bool, requested: Bool) -> Bool {
        switch mode {
        case .smoke: false
        case .demo: requested
        case .normal: requested || !completed
        }
    }
}

/// The browser extension's version, as it says in its `hello`.
public struct ExtensionVersion: Comparable, Sendable, CustomStringConvertible {
    /// The extension this build of Ahenk carries (`Extension/manifest.json`;
    /// a test keeps the two equal). 1.2.0 added the speed command.
    public static let shipped = ExtensionVersion(major: 1, minor: 2, patch: 0)

    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// "1.2", "1.2.0" or "v1.10.3"; `nil` for anything else.
    public init?(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("v") { trimmed.removeFirst() }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let number = Int(part), number >= 0 else { return nil }
            numbers.append(number)
        }
        while numbers.count < 3 { numbers.append(0) }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    public static func < (lhs: ExtensionVersion, rhs: ExtensionVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    /// A connected extension older than the one Ahenk carries: the browser
    /// still runs the old scripts until it is reloaded from the folder.
    /// An unreadable version is not flagged.
    public static func needsReload(reported: String) -> Bool {
        guard let version = ExtensionVersion(reported) else { return false }
        return version < shipped
    }
}
