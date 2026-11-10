import Foundation

/// Putting things back when a music app comes to the front by itself.
/// Spotify's `play track` brings Spotify forward and shows its window (its
/// own doing since late 2024; nothing in the script asks for it), so a pick
/// in Ahenk's player would throw the user into Spotify.
///
/// Being "in front" is not the point: what the user sees is. Ahenk's own
/// windows lie on the desktop, so making Ahenk the active app again leaves
/// the music app's window on top of everything. The music app goes back to
/// where it was: away, if it had no window on screen; behind the window
/// that was on top, if it had one.
public enum FocusKeeping {
    public enum Step: String, Equatable, Sendable {
        /// Hide the music app.
        case hide
        /// Hide it only if it is still in front (the steps before failed).
        case hideIfStillInFront
        /// Activate the app whose window was on top, so it covers the
        /// music app's again.
        case activateCover
        /// Open that app (it runs: this only activates it), if activating
        /// did not bring it forward. macOS honours it when it ignores a
        /// plain activation from an app that is not in front itself.
        case reopenCover
        /// Make the app the user typed or clicked in the active one again.
        case activatePrevious
    }

    /// How often things are put back during one start (a start may say
    /// "play" up to six times, and each brings the app forward).
    public static let maximumReturns = 6
    /// How long the front is watched after the start.
    public static let watchAfterStart: TimeInterval = 1.5
    /// How long one step gets before the next is tried.
    public static let stepPatience: TimeInterval = 0.3

    /// What the user saw before the start.
    public struct Before: Equatable, Sendable {
        /// The music app had a window on this screen (not hidden, not
        /// minimized, not on another Space).
        public var musicAppWasVisible: Bool
        /// Another app's window was on screen (the topmost such app is the
        /// "cover"): Ahenk's own desktop windows do not count.
        public var hasCover: Bool
        /// The cover may be reopened: an app with a Dock icon, not Finder
        /// (which would open a new window).
        public var coverCanReopen: Bool
        /// The cover is the app that was active (else Ahenk or Finder was,
        /// with the cover's window only on top).
        public var coverIsPrevious: Bool

        public init(musicAppWasVisible: Bool, hasCover: Bool, coverCanReopen: Bool, coverIsPrevious: Bool) {
            self.musicAppWasVisible = musicAppWasVisible
            self.hasCover = hasCover
            self.coverCanReopen = coverCanReopen
            self.coverIsPrevious = coverIsPrevious
        }
    }

    /// What to do, in order, once the music app has come forward.
    ///
    /// - It had no window on screen: it is hidden, and the app that was
    ///   active is made active again.
    /// - It had one, under another app's: that app is brought forward
    ///   again (hiding the music app remains the way out), then the app
    ///   that was active, if it is another.
    /// - It had one and nothing over it: only the active app changes back.
    public static func steps(_ before: Before) -> [Step] {
        guard before.musicAppWasVisible else { return [.hide, .activatePrevious] }
        guard before.hasCover else { return [.activatePrevious] }
        var steps: [Step] = [.activateCover]
        if before.coverCanReopen { steps.append(.reopenCover) }
        steps.append(.hideIfStillInFront)
        if !before.coverIsPrevious { steps.append(.activatePrevious) }
        return steps
    }
}
