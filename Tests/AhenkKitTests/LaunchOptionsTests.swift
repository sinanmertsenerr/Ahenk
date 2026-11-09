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

    @Test("Launch options for lyrics checks")
    func launchOptions() {
        let options = LaunchOptions(arguments: ["Ahenk", "--demo", "--lyrics-style", "neon", "--demo-position=12.5", "--draw-covered", "--smoke-only", "lyrics, menus"])
        #expect(options.lyricsStyle == "neon" && options.demoPosition == 12.5 && options.drawCovered)
        #expect(options.smokeChecks == ["lyrics", "menus"])
        #expect(options.usesDetachedSettings, "a style for one run is never saved")
        #expect(LaunchOptions(arguments: ["Ahenk", "--smoke-only"]).smokeChecks == nil)
    }

    @Test("Launch options for the desktop extras' demo")
    func desktopExtras() {
        let options = LaunchOptions(arguments: ["Ahenk", "--demo", "--demo-local", "--demo-desk-cleared"])
        #expect(options.mode == .demo && options.demoLocal && options.demoDeskCleared)
        let plain = LaunchOptions(arguments: ["Ahenk", "--demo-local", "--demo-desk-cleared"])
        #expect(plain.mode == .normal, "neither turns the demo on by itself")
        #expect(!LaunchOptions(arguments: ["Ahenk", "--demo"]).demoLocal)
        let measured = LaunchOptions(arguments: ["Ahenk", "--demo", "--full-rate", "--dock-art=Still"])
        #expect(measured.fullRate && measured.dockArt == "still")
        #expect(measured.usesDetachedSettings, "what a measurement switches is never saved")
        #expect(LaunchOptions(arguments: ["Ahenk", "--demo", "--dock-art", "off"]).usesDetachedSettings)
        #expect(!options.usesDetachedSettings)
    }

    @Test("Launch options for the live bridge check")
    func bridgeOptions() {
        let options = LaunchOptions(arguments: ["Ahenk", "--smoke", "--smoke-only", "bridgeLive", "--bridge-port", "43120", "--bridge-wait=45"])
        #expect(options.mode == .smoke && options.bridgePort == 43_120 && options.bridgeWait == 45)
        #expect(LaunchOptions(arguments: ["Ahenk", "--bridge-port", "80"]).bridgePort == nil, "a privileged port is refused")
        #expect(LaunchOptions(arguments: ["Ahenk", "--bridge-wait", "-3"]).bridgeWait == nil)
    }

    @Test("Launch options for live wallpaper checks")
    func wallpaperOptions() {
        let options = LaunchOptions(arguments: ["Ahenk", "--demo", "--wallpaper-song", "Glass Harbor | Nova Atlas", "--wallpaper-source=songVideo"])
        #expect(options.wallpaperSong?.title == "Glass Harbor" && options.wallpaperSong?.artist == "Nova Atlas")
        #expect(options.wallpaperSource == "songVideo")
        #expect(LaunchOptions(arguments: ["Ahenk", "--wallpaper-song", "No artist"]).wallpaperSong == nil)
        #expect(options.wallpaperSong?.duration == 0)
        #expect(LaunchOptions(arguments: ["Ahenk", "--wallpaper-song", "Glass Harbor|Nova Atlas|212"]).wallpaperSong?.duration == 212)
        #expect(options.usesDetachedSettings, "a run that picks the source never saves")
        #expect(!LaunchOptions(arguments: ["Ahenk", "--demo", "--wallpaper-song", "A|B"]).usesDetachedSettings)
        let optimized = LaunchOptions(arguments: ["Ahenk", "--demo", "--optimized"])
        #expect(optimized.optimized && optimized.usesDetachedSettings)
    }
}
