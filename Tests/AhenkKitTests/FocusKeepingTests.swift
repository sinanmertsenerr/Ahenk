import Testing
@testable import AhenkKit

@Suite("Keeping a music app in the background")
struct FocusKeepingTests {
    @Test("A music app that was hidden is hidden again first")
    func hidden() {
        #expect(FocusKeeping.steps(wasHidden: true, previousIsRegularApp: true, previousIsFinder: false) == [.hide, .activatePrevious, .reopenPrevious])
        #expect(FocusKeeping.steps(wasHidden: true, previousIsRegularApp: true, previousIsFinder: true) == [.hide, .activatePrevious])
    }

    @Test("A visible one stays visible if the front can be given back")
    func visible() {
        #expect(FocusKeeping.steps(wasHidden: false, previousIsRegularApp: true, previousIsFinder: false) == [.activatePrevious, .reopenPrevious, .hide])
    }

    @Test("Finder and apps without a Dock icon are never reopened")
    func neverReopened() {
        #expect(FocusKeeping.steps(wasHidden: false, previousIsRegularApp: true, previousIsFinder: true) == [.activatePrevious, .hide])
        #expect(FocusKeeping.steps(wasHidden: false, previousIsRegularApp: false, previousIsFinder: false) == [.activatePrevious, .hide])
        for hidden in [true, false] {
            for regular in [true, false] {
                let steps = FocusKeeping.steps(wasHidden: hidden, previousIsRegularApp: regular, previousIsFinder: true)
                #expect(!steps.contains(.reopenPrevious))
                #expect(steps.contains(.hide), "hiding always remains as a way out")
            }
        }
    }
}
