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

    @Test("Unknown and system arguments are ignored")
    func ignoresUnknown() {
        let options = parse("-NSDocumentRevisionsDebugMode", "YES", "--frobnicate", "-psn_0_12345", "--demo")
        #expect(options.mode == .demo)
    }
}
