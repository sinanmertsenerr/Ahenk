import Testing
@testable import AhenkKit

@Suite("Keeping a music app in the background")
struct FocusKeepingTests {
    typealias Before = FocusKeeping.Before

    @Test("A music app without a window on screen is hidden again, whatever was in front")
    func notVisible() {
        for cover in [true, false] {
            for reopen in [true, false] {
                for previous in [true, false] {
                    let before = Before(musicAppWasVisible: false, hasCover: cover, coverCanReopen: reopen, coverIsPrevious: previous)
                    #expect(FocusKeeping.steps(before) == [.hide, .activatePrevious])
                }
            }
        }
    }

    @Test("A visible one goes back under the window that was on top")
    func covered() {
        #expect(FocusKeeping.steps(Before(musicAppWasVisible: true, hasCover: true, coverCanReopen: true, coverIsPrevious: true))
            == [.activateCover, .reopenCover, .hideIfStillInFront])
        #expect(FocusKeeping.steps(Before(musicAppWasVisible: true, hasCover: true, coverCanReopen: true, coverIsPrevious: false))
            == [.activateCover, .reopenCover, .hideIfStillInFront, .activatePrevious],
            "typed in Ahenk's search with another app's window on top: that window first, then Ahenk is active again")
    }

    @Test("Finder and apps without a Dock icon are never reopened")
    func neverReopened() {
        #expect(FocusKeeping.steps(Before(musicAppWasVisible: true, hasCover: true, coverCanReopen: false, coverIsPrevious: true))
            == [.activateCover, .hideIfStillInFront])
    }

    @Test("A visible one with nothing over it keeps its place; only the active app changes back")
    func nothingOver() {
        #expect(FocusKeeping.steps(Before(musicAppWasVisible: true, hasCover: false, coverCanReopen: false, coverIsPrevious: false)) == [.activatePrevious])
    }
}
