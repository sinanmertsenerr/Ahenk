import Testing
@testable import AhenkKit

@Suite("LaunchOptions")
struct LaunchOptionsTests {
    private func parse(_ arguments: String...) -> LaunchOptions {
        LaunchOptions(arguments: ["/Applications/Ahenk.app/Contents/MacOS/Ahenk"] + arguments)
    }

    @Test("No arguments is a normal launch")
    func normal() {
        let options = parse()
        #expect(options.mode == .normal)
        #expect(!options.usesDemoContent)
        #expect(options.settingsPane == nil && options.snapshotDirectory == nil)
    }

    @Test("Demo and smoke modes")
    func modes() {
        #expect(parse("--demo").mode == .demo)
        #expect(parse("--smoke").mode == .smoke)
        #expect(parse("--demo", "--smoke").mode == .smoke)
        #expect(parse("--smoke", "--demo").mode == .smoke, "smoke wins regardless of order")
        #expect(parse("--smoke").usesDemoContent)
        let conflict = parse("--demo-conflict")
        #expect(conflict.mode == .demo && conflict.demoConflict)
        #expect(!parse("--demo").demoConflict)
        #expect(parse("--smoke", "--demo-conflict").mode == .smoke)
    }

    @Test("Settings pane in both spellings")
    func settingsPane() {
        #expect(parse("--settings").settingsPane == "")
        #expect(parse("--settings", "light").settingsPane == "light")
        #expect(parse("--settings=lyrics").settingsPane == "lyrics")
        #expect(parse("--settings", "--demo").settingsPane == "", "a following flag is not a value")
        #expect(parse("--settings", "--demo").mode == .demo)
    }

    @Test("Snapshots and multiple instances")
    func extras() {
        let options = parse("--smoke", "--snapshots", "/tmp/shots", "--allow-multiple")
        #expect(options.snapshotDirectory == "/tmp/shots")
        #expect(options.allowsMultipleInstances)
        #expect(parse("--snapshots").snapshotDirectory == "")
    }

    @Test("Demo pause and resume times")
    func demoCommands() {
        let options = parse("--demo", "--demo-pause-after", "6", "--demo-resume-after=12.5")
        #expect(options.demoPauseAfter == 6 && options.demoResumeAfter == 12.5)
        #expect(parse("--demo").demoPauseAfter == nil)
        #expect(parse("--demo-pause-after", "soon").demoPauseAfter == nil)
        #expect(parse("--demo-pause-after", "-3").demoPauseAfter == nil, "a negative number reads as a flag, not a value")
        #expect(parse("--demo-pause-after=-3").demoPauseAfter == nil)
    }

    @Test("Demo scenes, the backdrop and a language for one run")
    func scenes() {
        let scene = parse("--demo-scene", "album", "--demo-backdrop", "--language", "TR")
        #expect(scene.mode == .demo && scene.demoScene == "album" && scene.demoBackdrop && scene.language == "tr")
        #expect(scene.usesDetachedSettings, "a scene never saves what it changes")
        #expect(parse("--demo-scene").demoScene == "albums")
        #expect(parse("--demo-scene=queue").demoScene == "queue")
        #expect(!parse("--demo").usesDetachedSettings)
        #expect(parse("--smoke").usesDetachedSettings)
        #expect(parse("--language=tr").usesDetachedSettings)
        #expect(parse("--smoke", "--demo-scene", "search").mode == .smoke)
    }

    @Test("Unknown and system arguments are ignored")
    func ignoresUnknown() {
        let options = parse("-NSDocumentRevisionsDebugMode", "YES", "--frobnicate", "-psn_0_12345", "--demo")
        #expect(options.mode == .demo)
    }
}
