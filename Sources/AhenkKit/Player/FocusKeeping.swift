import Foundation

/// Giving the front back to the app the user works in, when a music app
/// takes it by itself. Spotify's `play track` brings Spotify to the front
/// (its own doing since late 2024; nothing in the script asks for it), so a
/// pick in Ahenk's player would throw the user into Spotify.
public enum FocusKeeping {
    public enum Step: String, Equatable, Sendable {
        /// Hide the music app: macOS then puts the app before it in front.
        case hide
        /// Ask macOS to activate the app that was in front.
        case activatePrevious
        /// Open the app that was in front (it runs: this only activates
        /// it). macOS honours it when it ignores a plain activation from an
        /// app that is not in front itself.
        case reopenPrevious
    }

    /// How often the front is given back during one start (a start may
    /// say "play" up to six times, and each brings the app forward).
    public static let maximumReturns = 6
    /// How long the front is watched after the start.
    public static let watchAfterStart: TimeInterval = 1.5
    /// How long one step gets before the next is tried.
    public static let stepPatience: TimeInterval = 0.3

    /// What to try, in order, until the music app is no longer in front.
    ///
    /// - A music app that was hidden is hidden again first: that alone
    ///   restores what the user saw.
    /// - One that was visible stays visible if it can: the app in front is
    ///   activated, reopened, and only if both fail the music app is hidden.
    /// - Finder is never reopened (it would open a new window), and neither
    ///   is an app without a Dock icon.
    public static func steps(wasHidden: Bool, previousIsRegularApp: Bool, previousIsFinder: Bool) -> [Step] {
        let reopen: [Step] = previousIsRegularApp && !previousIsFinder ? [.reopenPrevious] : []
        if wasHidden {
            return [.hide, .activatePrevious] + reopen
        }
        return [.activatePrevious] + reopen + [.hide]
    }
}
