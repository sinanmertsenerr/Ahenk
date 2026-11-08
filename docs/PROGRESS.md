# Ahenk — progress

One entry per step: what exists, how to verify it, the decisions taken and
what the next steps must know. The master plan (`docs/PLAN.md`) is kept on
the maintainer's Mac only; see "Decisions" below.

## Step 1 — Foundation, repo, app shell (done, 2026-11-08)

### What exists

```
Package.swift                 tools 6.0, macOS 14; AhenkKit (Swift 6), AhenkApp → product "Ahenk" (Swift 5), AhenkKitTests
Sources/AhenkKit/
  Settings/   AppSettings (observable, Codable, UserDefaults), SettingsGroups, SettingsOptions,
              LenientDecoding, QuickToggle
  Models/     MusicSource, Track, NowPlayingSnapshot (+ RepeatMode), PlaybackCommand, SyncedLyrics
  NowPlaying/ NowPlayingProvider, Artwork + ArtworkProvider
  Lyrics/     LyricsQuery, LyricsResult, LyricsProvider
  Audio/      AudioFeatures, AudioFeatureSource
  Color/      SRGBColor, Palette
  Demo/       DemoProvider, DemoCatalog (4 invented songs), DemoArtwork (generated covers), DemoBeat (120 BPM)
  Support/    Log + AhenkLogger + LogFile, LaunchOptions, SmokeReport, ChangeObserver
Sources/AhenkApp/
  App/        AhenkMain (@main), AppDelegate, AppEnvironment, Menus (menu bar extra, Dock menu, main menu),
              SmokeRunner, DeskClearing (Clear Desk placeholder)
  NowPlaying/ NowPlayingModel (what the UI shows; fed by the demo provider in Step 1)
  Light/      MetalShaders (runtime compilation), MetalProbe (offscreen frames for --smoke)
  Settings/   SettingsWindowController, SettingsRootView, SettingsPane, SettingsComponents, OptionTitles,
              Panes/{General,Sources,Light,Player,Lyrics,Wallpaper,Sound,Stickers,About}Pane
  Support/    L10n, ResourceBundle, AppInfo, ColorBridge, DisplayIdentity, MenuBarIcon
  Resources/  tr.lproj/Localizable.strings, Shaders/EdgeLight.metal
Tests/AhenkKitTests/          76 tests in 10 suites (settings, logging, demo, models, smoke report,
                              change observer, localization coverage)
Packaging/                    Info.plist template, Ahenk.entitlements, en/tr.lproj/InfoPlist.strings
Vendor/mediaremote-adapter/   BSD-3, sources + perl script + header + LICENSE (no build output)
Scripts/                      make-app.sh build-adapter.sh test.sh install.sh run-demo.sh smoke.sh
```

The running app today: a regular app with a Dock icon and a menu bar extra.
The menu shows the current song (in demo mode), the five quick toggles (Edge
Light, Desktop Player, Lyrics, Live Wallpaper, Dock Art) bound to the
settings, Clear Desk (disabled until Step 9), Settings… and Quit. The Dock
menu has the same toggles. Clicking the Dock icon opens Settings. The Settings
window has a sidebar with General, Sources, Edge Light, Desktop Player,
Lyrics, Live Wallpaper, Sound, Stickers and About; every control is bound to
the real setting and persists, even where the feature arrives later. English
and Turkish switch live (Settings › General › Language).

### Build, run, verify

```sh
swift build && swift test             # 76 tests, no warnings
./Scripts/test.sh                     # plist/strings lint + script syntax + swift test
./Scripts/make-app.sh                 # dist/Ahenk.app, signed with the Apple Development identity
codesign -dvv dist/Ahenk.app 2>&1 | grep Authority
./Scripts/smoke.sh [--snapshots]      # open -W -n dist/Ahenk.app --args --smoke; prints smoke.json
./Scripts/run-demo.sh                 # build + open -n dist/Ahenk.app --args --demo
pkill -x Ahenk                        # quits through applicationWillTerminate (SIGTERM is handled)
AHENK_INSTALL_ROOT=$(mktemp -d) ./Scripts/install.sh   # install rehearsal; without the variable: /Applications
```

Launch arguments (`open -n dist/Ahenk.app --args …`): `--demo`, `--smoke`,
`--snapshots [dir]` (with `--smoke`: PNG of every Settings pane in both
languages, default `~/Library/Logs/Ahenk/snapshots`), `--settings [pane]`
(open Settings at `general|sources|light|player|lyrics|wallpaper|sound|stickers|about`),
`--allow-multiple` (skip the single-instance hand-off).

Smoke checks (all `ok` for the packaged app): launch, logging, settings,
localization, resources (shader + every SF Symbol), adapter (bundled script,
Mach-O framework, LICENSE), demo, nowPlaying (model receives song, cover,
lyrics, features), metal (compile EdgeLight.metal, render 3 frames offscreen,
edge brighter than centre), menus (menu bar, Dock and main menu in both
languages; a toggle item really flips its setting), settingsWindow (all 9
panes × 2 languages drawn in an invisible window). Each later step adds a
check for its subsystem in `SmokeRunner`.

Measured on the M5 dev Mac (release build): demo running with no window
0% CPU; Settings open on General (demo card) ~1–2%; on Sound (live
spectrum, 30 fps) ~0.2%. Cold compile of EdgeLight.metal ~280 ms.

Logs: `~/Library/Logs/Ahenk/Ahenk.log` (rolls at 1 MB, keeps 3) and the unified
log, subsystem `com.sinanmertsener.Ahenk`. Settings:
`defaults read com.sinanmertsener.Ahenk settings`.

### Settings model (AppSettings)

One `@Observable final class AppSettings: Codable` in AhenkKit. Observation
is per group, so code that reads `settings.light` is only invalidated by light
changes. Every change is written at once to `UserDefaults` (key `settings`, a
readable dictionary with `schemaVersion`). Decoding is lenient per field: a
missing key, a wrong type or an unknown enum case resets only that field, and
numbers are clamped to the ranges declared next to them (sliders use the same
ranges). `AppSettings(defaults:)` persists, `AppSettings()` and
`AppSettings.detachedCopy(of:)` do not (smoke runs use a detached copy).

| Group | Settings | Feature step |
|---|---|---|
| `general` | language, optimizedMode, lighterOnBattery, showSongTitleInMenuBar, storefront, onboardingCompleted, verboseLogging | 1, 2, 5, 11 |
| `sources` | selection (automatic / pinned source), askWhenSeveralPlay, pauseOthersOnSwitch, ignoredSources, browserBridgeEnabled, browserBridgePort | 2, 7 |
| `light` | enabled, style (22), position, thickness, glow, intensity, speed, colorSource, customColors, disabledDisplays, onlyOnDesktop, stepAsideInFullScreen | 4 |
| `player` | enabled, size, displayID, showClock, showDate, clockFormat, showContinuePlaying, showAlbums, showSearch, startAtFifteenSeconds | 2, 5 |
| `lyrics` | enabled, style (8), showAlbumArt, textScale, useAlbumColors, instrumentalCountdown, autoSync, globalOffset, disabledProviders, localAlignment, whisperExecutablePath, whisperModelPath | 6, 10 |
| `wallpaper` | enabled, useMotionArtwork, useMusicVideos, useArtworkFallback, crossfadeDuration, dimming, savedVideos, selectedVideoID | 8 |
| `dock` | albumArtIcon, beatRing | 9 |
| `audio` | sensitivity | 3 |
| `effects` | enabled, preset (9), speed, pitch, reverb, equalizerEnabled, equalizerBands (10) | 10 |
| `stickers` | enabled, border | 9 |
| `layout` | positions (widget × display, normalized) | 5, 9 |

Adding a setting: give it a default, decode it in the group's `init(from:)`
with `lenient`, add a non-default value to `AppSettingsTests.everythingChanged`
(a test fails until you do), never rename a stored property without a
migration. Per-item data that grows (lyric offsets, recently played, sticker
images, artist overrides) belongs in the feature's own store under
`~/Library/Application Support/Ahenk`, not in AppSettings. Launch at login is
system state (SMAppService, Step 11), not a stored setting.

### Decisions

- **Metal shaders: runtime compilation.** `.metal` sources ship in the
  resource bundle (`Resources/Shaders`, copied as is) and
  `MetalShaders.makeLibrary(named:device:)` compiles them with
  `makeLibrary(source:options:)`. Precompiling in make-app.sh is not possible
  here: `xcrun metal` needs Xcode's separately downloaded Metal toolchain,
  which is not installed. `swift run` and the packaged app behave the same.
  Step 4: compile once, off the main thread, at launch; keep
  `EdgeLightUniforms` (Swift) in sync with the shader struct.
- **AppKit lifecycle, SwiftUI content.** `@main AhenkMain` + `AppDelegate`,
  `NSStatusItem` menus rebuilt on open, Settings as SwiftUI in an
  `NSHostingController` window. Full control over launch modes, windows and
  menus; no SwiftUI scene graph to fight.
- **Live visuals in Settings must not re-render SwiftUI per frame.** Every
  SwiftUI update re-lays out the whole Settings window (several ms; more inside
  a grouped Form). A 12 fps timeline in the Sound form cost ~28% CPU. Use leaf
  AppKit views that redraw themselves (`SpectrumBarsView`) or low-frequency
  timelines outside the Form (the demo card refreshes twice a second).
- **Localization.** Keys are the English text; Turkish lives in the SwiftPM
  resource bundle (`Ahenk_AhenkApp.bundle/tr.lproj`). Never `Bundle.module`
  (its accessor crashes when the bundle is not where SwiftPM expects);
  `ResourceBundle` searches the app's Resources and the executable's folder.
  The language is an in-app setting, English by default.
  `LocalizationCoverageTests` fail on a missing, unused or malformed entry,
  on a suffix glued to a placeholder, and on a SwiftUI control given a bare
  literal. Permission texts are localized in `Packaging/*.lproj/InfoPlist.strings`.
- **Single instance.** A second launch brings the running Ahenk forward and
  quits (not for `--smoke` or `--allow-multiple`).
- **Graceful SIGTERM/SIGINT.** `pkill -x Ahenk` goes through
  `applicationWillTerminate`, where later steps must undo their desktop changes
  (wallpaper, hidden apps, the adapter child process).
- **Signing.** make-app.sh signs with the identity whose SHA-1 is
  `5977683A720BD3729B68F45D1780461EB8B8B19A` (the Apple Development
  certificate), the nested adapter framework first; it falls back to ad hoc
  with a loud warning. `install.sh` refuses ad hoc builds unless
  `ALLOW_ADHOC=1`. Hardened runtime; the only entitlement is
  `com.apple.security.automation.apple-events`; no sandbox.
- **Adapter.** Built by `build-adapter.sh` with clang and `-fobjc-arc`, as
  upstream's CMakeLists does. make-app.sh rebuilds it when its sources are
  newer and bundles `Contents/Resources/adapter/{mediaremote-adapter.pl,
  MediaRemoteAdapter.framework, LICENSE}`. Not linked; not run yet.
- **`SRGBColor`, not `RGBColor`.** AppKit still exports QuickDraw's
  `RGBColor`, which made the name ambiguous in every AppKit file.
- **Turkish dotless i.** String matching must fold case locale-neutrally
  (`compare(_:options:range:locale: nil)`); with a Turkish locale "DRIVE" does
  not match "Drive" otherwise (a test caught it on this Mac).
- **Log file opened with O_APPEND**, so a smoke run next to a running Ahenk
  appends whole lines instead of overwriting the other process's lines.

### Deviations from PLAN.md

- `docs/PLAN.md` is git-ignored: its reference path names the product being
  re-implemented (hard rule 1) and it contains a personal e-mail address.
  Engineers read it at `~/Desktop/Ahenk/docs/PLAN.md` as before.
- New folders beyond the planned tree: `Packaging/` (Info.plist template,
  entitlements, localized permission texts), `Sources/AhenkApp/Settings/`
  (the Settings window), `Sources/AhenkKit/Demo/` and `Support/`.
- Extra script: `Scripts/smoke.sh` (launch `--smoke`, wait, print and check
  the report).
- Sidebar titles use the feature names ("Edge Light", "Desktop Player",
  "Live Wallpaper"); the pane identifiers stay `light`, `player`, `wallpaper`.
- The edge light style `.glow` is shown as "Soft Glow" (Turkish needs
  different words for the style and for the Glow slider).

### For Step 2 and later

- **Now playing.** Implement providers against `NowPlayingProvider`
  (snapshots stream + `perform`). `NowPlayingModel.attach(provider:artwork:lyrics:features:)`
  is what the UI follows today; put the hub in front of it (or replace the
  model and update `QuickMenu`, `DemoNowPlayingCard`, `SpectrumView`,
  `SmokeRunner`). Wire it in `AppDelegate.startServices()`. `DemoProvider`
  is a complete provider (commands included) for tests and `--demo`.
- **Adapter paths.** `AppInfo.adapterDirectory` (packaged app). Dev runs
  (`swift run`) have no bundle; port DynamicIsland's `AdapterLocator`
  (DEBUG fallback to `Vendor/mediaremote-adapter/{bin,build}`). Terminate the
  perl child in `applicationWillTerminate`.
- **Sources.** `MusicSource` raw values are persisted; add cases, never rename.
  `sources.selection`, `askWhenSeveralPlay`, `pauseOthersOnSwitch` and
  `ignoredSources` are ready for the hub; `player.startAtFifteenSeconds` too.
- **Menu bar song.** `QuickMenu` already lists the current song from
  `NowPlayingModel.snapshot`; `general.showSongTitleInMenuBar` puts the title
  next to the icon (`StatusMenuController`).
- **Lyrics (Step 6).** `SyncedLyrics`/`LyricLine`/`LyricWord` are DynamicIsland's
  model; `LyricsProvider` has `name` + `fetch`. Add the provenance-aware
  requirements with default implementations when porting the chain.
- **Audio (Step 3).** Produce `AudioFeatures` through `AudioFeatureSource`
  (polled from render loops; must be cheap and lock-light). Replace the Sound
  pane's `SpectrumView` source; keep drawing in AppKit.
- **Reacting to settings.** `ChangeObserver({ settings.light }) { … }` on the
  main actor; keep the observer object alive.
- **Logging.** `AhenkLogger(category:)`; `debug` only reaches the file with
  verbose logging on.
- **UI text.** Every user-facing string goes through `"English".l10n` or
  `L10n.format`, with its Turkish entry; never glue a suffix to a placeholder.
- **Clear Desk (Step 9).** Implement `DeskClearing` and assign
  `environment.clearDesk`; the menu enables the item by itself.
- **Smoke.** Add a check in `SmokeRunner.run()` for each new subsystem; it
  must not touch permission-protected APIs. Snapshots render panes in an
  invisible window; the glass sidebar comes out blank in them.

### Known gaps and risks

- No app icon yet (generic icon in Finder/Dock; Step 11 generates one).
- Launch at login and onboarding are not implemented (Step 11).
- The Settings sidebar could not be checked visually from the shell (the
  glass sidebar is blank in snapshots, and screen capture would need a
  permission); the pane content was checked in both languages.
- `--smoke` exits 0 even when a check fails (as the plan asks); read `ok` in
  smoke.json or use `./Scripts/smoke.sh`, which exits non-zero.
- Two Ahenk processes writing the same log file at the moment it rolls over
  can leave one of them writing into `Ahenk.1.log` until it restarts.
