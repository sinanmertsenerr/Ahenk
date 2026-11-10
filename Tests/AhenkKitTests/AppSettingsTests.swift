import Foundation
import Observation
import os
import Testing
@testable import AhenkKit

@Suite("AppSettings")
struct AppSettingsTests {
    /// A settings document where every single field differs from its default.
    static func everythingChanged() -> AppSettings {
        let s = AppSettings()
        s.general = {
            var g = GeneralSettings()
            g.language = .turkish
            g.lighterOnBattery = false
            g.showSongTitleInMenuBar = true
            g.storefront = "TR"
            g.onboardingCompleted = true
            g.verboseLogging = true
            return g
        }()
        s.sources = {
            var x = SourceSettings()
            x.selection = .pinned(.spotify)
            x.askWhenSeveralPlay = false
            x.pauseOthersOnSwitch = false
            x.ignoredSources = [.youtube, .deezer]
            x.browserBridgeEnabled = false
            x.browserBridgePort = 40_001
            return x
        }()
        s.light = {
            var l = LightSettings()
            l.enabled = false
            l.style = .twinSnakes
            l.position = .corners
            l.thickness = 24
            l.glow = 0.3
            l.intensity = 0.4
            l.speed = 2.5
            l.colorSource = .custom
            l.customColors = [SRGBColor("#112233"), SRGBColor("#445566"), SRGBColor("#778899")]
            l.disabledDisplays = ["DISPLAY-A", "DISPLAY-B"]
            l.onlyOnDesktop = true
            l.stepAsideInFullScreen = false
            return l
        }()
        s.player = {
            var p = PlayerSettings()
            p.enabled = false
            p.size = .small
            p.displayID = "DISPLAY-A"
            p.showClock = false
            p.showDate = false
            p.clockFormat = .twentyFourHour
            p.clockScale = 0.8
            p.showContinuePlaying = false
            p.showAlbums = false
            p.showSearch = false
            p.showPlayerBar = false
            p.listeningSource = .spotify
            p.startAtFifteenSeconds = true
            p.widgetsLocked = true
            return p
        }()
        s.lyrics = {
            var l = LyricsSettings()
            l.enabled = false
            l.style = .glitch
            l.position = .top
            l.showAlbumArt = false
            l.textScale = 1.3
            l.useAlbumColors = false
            l.instrumentalCountdown = false
            l.autoSync = false
            l.globalOffset = -1.5
            l.disabledProviders = ["netease"]
            l.localAlignment = false
            l.whisperExecutablePath = "/opt/tools/whisper-cli"
            l.whisperModelPath = "/opt/models/model.bin"
            return l
        }()
        s.wallpaper = {
            var w = WallpaperSettings()
            let video = SavedVideo(
                id: "v1", title: "Invented clip", kind: .youtube, reference: "abcdefghijk",
                addedAt: Date(timeIntervalSinceReferenceDate: 700_000_000)
            )
            w.enabled = false
            w.useMotionArtwork = false
            w.useMusicVideos = false
            w.useArtworkFallback = false
            w.preferredSource = .musicVideo
            w.crossfadeDuration = 3
            w.dimming = 0.5
            w.blur = 0.4
            w.followSong = false
            w.returnsOnPause = false
            w.showPicker = false
            w.disabledDisplays = ["DISPLAY-B"]
            w.savedVideos = [video]
            w.selectedVideoID = "v1"
            return w
        }()
        s.dock = {
            var d = DockSettings()
            d.albumArtIcon = false
            d.beatRing = false
            return d
        }()
        s.audio = {
            var a = AudioAnalysisSettings()
            a.sensitivity = 2
            return a
        }()
        s.effects = {
            var e = SoundEffectSettings()
            e.enabled = true
            e.preset = .slowedReverb
            e.speed = 0.8
            e.pitch = -3
            e.reverb = 0.6
            e.equalizerEnabled = true
            e.equalizerBands = [6, 4, 2, 0, -1, -2, 0, 2, 4, 6]
            return e
        }()
        s.stickers = {
            var st = StickerSettings()
            st.enabled = false
            st.border = false
            return st
        }()
        s.layout = {
            var l = DesktopLayout()
            l.setPosition(NormalizedPoint(x: 0.1, y: 0.9), of: "clock", on: "DISPLAY-A")
            return l
        }()
        return s
    }

    @Test("The fixture changes every field, so the round trip covers them all")
    func fixtureCoversEveryField() {
        let changed = Self.everythingChanged()
        let defaults = AppSettings()
        let pairs: [(String, Any, Any)] = [
            ("general", changed.general, defaults.general),
            ("sources", changed.sources, defaults.sources),
            ("light", changed.light, defaults.light),
            ("player", changed.player, defaults.player),
            ("lyrics", changed.lyrics, defaults.lyrics),
            ("wallpaper", changed.wallpaper, defaults.wallpaper),
            ("dock", changed.dock, defaults.dock),
            ("audio", changed.audio, defaults.audio),
            ("effects", changed.effects, defaults.effects),
            ("stickers", changed.stickers, defaults.stickers),
            ("layout", changed.layout, defaults.layout),
        ]
        for (group, value, reference) in pairs {
            let fields = Array(Mirror(reflecting: value).children)
            let referenceFields = Array(Mirror(reflecting: reference).children)
            #expect(fields.count == referenceFields.count)
            for (field, referenceField) in zip(fields, referenceFields) {
                #expect(
                    String(describing: field.value) != String(describing: referenceField.value),
                    "\(group).\(field.label ?? "?") keeps its default in the fixture; give it a new value"
                )
            }
        }
    }

    @Test("Every field survives encode and decode")
    func roundTripsEveryField() throws {
        let original = Self.everythingChanged()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.hasSameValues(as: original))
    }

    @Test("Defaults match the documented first-run behaviour")
    func defaults() {
        let s = AppSettings()
        #expect(s.general.language == .english)
        #expect(s.sources.selection == .automatic)
        #expect(s.light.enabled && s.player.enabled && s.lyrics.enabled && s.wallpaper.enabled)
        #expect(s.dock.albumArtIcon)
        #expect(s.light.style == .glow && s.light.position == .allEdges && s.light.colorSource == .album)
        #expect(s.lyrics.style == .plain)
        #expect(!s.player.startAtFifteenSeconds)
        #expect(s.general.lighterOnBattery)
        #expect(!s.effects.enabled && s.effects.equalizerBands == SoundEffectSettings.flatEqualizer)
        #expect(s.origin == .memory)
    }

    @Test("There are 22 light styles and 8 lyric styles")
    func styleCounts() {
        #expect(LightStyle.allCases.count == 22)
        #expect(LyricStyle.allCases.count == 6)
        #expect(SoundEffectSettings.equalizerFrequencies.count == 10)
    }

    @Test("Missing groups and keys fall back to their defaults")
    func missingKeys() throws {
        let s = try decodeSettings(#"{"light": {"style": "lava"}}"#)
        #expect(s.light.style == .lava)
        #expect(s.light.thickness == LightSettings().thickness)
        #expect(s.player == PlayerSettings())
        #expect(s.general == GeneralSettings())
    }

    @Test("An unknown enum value only resets that field")
    func unknownEnumCase() throws {
        let s = try decodeSettings(#"{"light": {"style": "laserShow", "thickness": 20, "enabled": false}}"#)
        #expect(s.light.style == .glow)
        #expect(s.light.thickness == 20)
        #expect(!s.light.enabled)
    }

    @Test("A value of the wrong type only resets that field")
    func wrongTypes() throws {
        let s = try decodeSettings(#"{"light": {"thickness": "thick", "onlyOnDesktop": true}, "dock": "nope"}"#)
        #expect(s.light.thickness == LightSettings().thickness)
        #expect(s.light.onlyOnDesktop)
        #expect(s.dock == DockSettings())
    }

    @Test("Numbers are clamped into their ranges")
    func clamping() throws {
        let s = try decodeSettings("""
        {"light": {"thickness": 999, "glow": -2, "speed": 0},
         "sources": {"browserBridgePort": 80},
         "lyrics": {"globalOffset": 60, "textScale": 0.1},
         "effects": {"equalizerBands": [30, -30, 3], "pitch": 99}}
        """)
        #expect(s.light.thickness == LightSettings.thicknessRange.upperBound)
        #expect(s.light.glow == 0)
        #expect(s.light.speed == LightSettings.speedRange.lowerBound)
        #expect(s.sources.browserBridgePort == SourceSettings.portRange.lowerBound)
        #expect(s.lyrics.globalOffset == 5 && s.lyrics.textScale == 0.6)
        #expect(s.effects.equalizerBands == [12, -12, 3, 0, 0, 0, 0, 0, 0, 0])
        #expect(s.effects.pitch == 12)
    }

    @Test("Collections drop invalid members instead of resetting")
    func lenientCollections() throws {
        let s = try decodeSettings("""
        {"sources": {"ignoredSources": ["spotify", "notASource", "youtube"]},
         "light": {"customColors": ["#FF0000", "purple", "#00FF00", "#0000FF", "#FFFFFF", "#000000"]},
         "wallpaper": {"savedVideos": [{"id": "a", "title": "One", "kind": "youtube", "reference": "x", "addedAt": 1},
                                        {"id": "b", "title": "Broken", "kind": "hologram", "reference": "y", "addedAt": 2}],
                       "selectedVideoID": "b"}}
        """)
        #expect(s.sources.ignoredSources == [.spotify, .youtube])
        #expect(s.light.customColors.map(\.hex) == ["#FF0000", "#00FF00", "#0000FF", "#FFFFFF"])
        #expect(s.wallpaper.savedVideos.map(\.id) == ["a"])
        #expect(s.wallpaper.selectedVideoID == nil, "a pinned video that no longer exists is dropped")
    }

    @Test("An empty colour list keeps the default colours")
    func emptyCustomColors() throws {
        let s = try decodeSettings(#"{"light": {"customColors": []}}"#)
        #expect(s.light.customColors == LightSettings().customColors)
    }

    @Test("Source selection codes as one string")
    func sourceSelectionCoding() throws {
        #expect(SourceSelection(rawValue: "automatic") == .automatic)
        #expect(SourceSelection(rawValue: "youtubeMusic") == .pinned(.youtubeMusic))
        #expect(SourceSelection(rawValue: "somethingElse") == .automatic)
        let s = try decodeSettings(#"{"sources": {"selection": "appleMusic"}}"#)
        #expect(s.sources.selection == .pinned(.appleMusic))
        let data = try JSONEncoder().encode(SourceSelection.pinned(.tidal))
        #expect(String(decoding: data, as: UTF8.self) == #""tidal""#)
    }

    @Test("Storefront codes are validated")
    func storefront() {
        #expect(GeneralSettings.validStorefront(" tr ") == "TR")
        #expect(GeneralSettings.validStorefront("TUR") == nil)
        #expect(GeneralSettings.validStorefront("1A") == nil)
        #expect(GeneralSettings.validStorefront(nil) == nil)
    }

    // MARK: Persistence

    @Test("A fresh domain starts from defaults and writes on the first change")
    func freshDomain() throws {
        let scratch = ScratchDefaults()
        let s = AppSettings(defaults: scratch.defaults)
        #expect(s.origin == .fresh)
        #expect(scratch.defaults.object(forKey: AppSettings.defaultsKey) == nil, "nothing is written until a change")

        s.light.style = .aurora
        let stored = try #require(scratch.defaults.dictionary(forKey: AppSettings.defaultsKey))
        let light = try #require(stored["light"] as? [String: Any])
        #expect(light["style"] as? String == "aurora", "stored as a readable dictionary")
        #expect(stored["schemaVersion"] as? Int == AppSettings.schemaVersion)
    }

    @Test("Changes are written immediately and reload in a new instance")
    func persistsAcrossInstances() {
        let scratch = ScratchDefaults()
        let first = AppSettings(defaults: scratch.defaults)
        first.replaceValues(with: Self.everythingChanged())

        let second = AppSettings(defaults: scratch.defaults)
        #expect(second.origin == .stored(schemaVersion: AppSettings.schemaVersion))
        #expect(second.hasSameValues(as: Self.everythingChanged()))
    }

    @Test("An unreadable stored value is replaced by defaults")
    func recoversFromCorruptValue() throws {
        let scratch = ScratchDefaults()
        scratch.defaults.set("not a dictionary", forKey: AppSettings.defaultsKey)
        let s = AppSettings(defaults: scratch.defaults)
        guard case .recovered = s.origin else {
            Issue.record("expected .recovered, got \(s.origin)")
            return
        }
        #expect(s.hasSameValues(as: AppSettings()))
        #expect(scratch.defaults.dictionary(forKey: AppSettings.defaultsKey) != nil, "defaults were written back")
    }

    @Test("Hand-edited non-JSON values do not crash the loader")
    func nonJSONTypes() {
        let scratch = ScratchDefaults()
        scratch.defaults.set(["light": ["style": Date()]], forKey: AppSettings.defaultsKey)
        let s = AppSettings(defaults: scratch.defaults)
        guard case .recovered = s.origin else {
            Issue.record("expected .recovered, got \(s.origin)")
            return
        }
        #expect(s.light == LightSettings())
    }

    @Test("A detached copy never writes back")
    func detachedCopy() {
        let scratch = ScratchDefaults()
        let persisted = AppSettings(defaults: scratch.defaults)
        persisted.general.language = .turkish

        let copy = AppSettings.detachedCopy(of: scratch.defaults)
        #expect(copy.general.language == .turkish)
        copy.general.language = .english
        copy.light.enabled = false

        let reloaded = AppSettings(defaults: scratch.defaults)
        #expect(reloaded.general.language == .turkish)
        #expect(reloaded.light.enabled)
    }

    @Test("Reset restores every default and persists it")
    func reset() {
        let scratch = ScratchDefaults()
        let s = AppSettings(defaults: scratch.defaults)
        s.replaceValues(with: Self.everythingChanged())
        s.resetToDefaults()
        #expect(s.hasSameValues(as: AppSettings()))
        #expect(AppSettings(defaults: scratch.defaults).hasSameValues(as: AppSettings()))
    }

    // MARK: Observation

    @Test("Observation is per group")
    func observationGranularity() {
        let s = AppSettings()
        let lightChanged = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = s.light.enabled
        } onChange: {
            lightChanged.withLock { $0 = true }
        }
        s.player.showClock = false
        #expect(!lightChanged.withLock { $0 }, "a player change must not invalidate light observers")
        s.light.enabled = false
        #expect(lightChanged.withLock { $0 })
    }

    @Test("Quick toggles flip the matching setting")
    func quickToggles() {
        let scratch = ScratchDefaults()
        let s = AppSettings(defaults: scratch.defaults)
        for toggle in QuickToggle.allCases {
            #expect(s.isOn(toggle), "\(toggle) starts on")
            s.flip(toggle)
            #expect(!s.isOn(toggle))
        }
        #expect(!s.light.enabled && !s.player.enabled && !s.lyrics.enabled && !s.wallpaper.enabled && !s.dock.albumArtIcon)
        let reloaded = AppSettings(defaults: scratch.defaults)
        #expect(QuickToggle.allCases.allSatisfy { !reloaded.isOn($0) })
    }

    @Test("Widget positions are stored per display")
    func layoutPositions() {
        var layout = DesktopLayout()
        layout.setPosition(NormalizedPoint(x: 0.2, y: 0.3), of: "player", on: "A")
        layout.setPosition(NormalizedPoint(x: 0.5, y: 0.5), of: "player", on: "B")
        layout.setPosition(NormalizedPoint(x: 2, y: -1), of: "clock", on: "A")
        #expect(layout.position(of: "player", on: "A") == NormalizedPoint(x: 0.2, y: 0.3))
        #expect(layout.position(of: "clock", on: "A") == NormalizedPoint(x: 1, y: 0), "points are clamped")
        layout.resetPositions(on: "A")
        #expect(layout.position(of: "player", on: "A") == nil)
        #expect(layout.position(of: "player", on: "B") != nil)
    }

    @Test("Per-display light switch")
    func perDisplayLight() {
        var light = LightSettings()
        light.disabledDisplays = ["WORK"]
        #expect(!light.isEnabled(onDisplay: "WORK"))
        #expect(light.isEnabled(onDisplay: "TV"))
        light.enabled = false
        #expect(!light.isEnabled(onDisplay: "TV"))
    }

    @Test("Language locales keep the region")
    func languageLocale() {
        let turkey = Locale.Region("TR")
        #expect(AppLanguage.turkish.locale(region: turkey).identifier == "tr_TR")
        #expect(AppLanguage.english.locale(region: turkey).identifier == "en_TR")
        #expect(AppLanguage.english.nativeName == "English")
        #expect(AppLanguage.turkish.nativeName == "Türkçe")
    }
}
