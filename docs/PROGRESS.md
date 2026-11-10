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
spectrum, 30 fps) ~0.2%. EdgeLight.metal compiles in ~280 ms cold; Metal's
shader cache answers later launches in ~1 ms.

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

## Step 2 — Now Playing hub (done, 2026-11-08)

### What exists

```
Sources/AhenkKit/
  Models/      NowPlayingSnapshot (+ ContentKind, PlaybackCapabilities, artwork bytes, pid), TrackMatching
  NowPlaying/
    MediaRemote/ AdapterPayload, NowPlayingStreamDecoder (+ LineSplitter), MediaRemoteCommand/Request,
                 MediaRemoteAdapter (perl child processes), MediaRemoteProvider (restart with backoff, health)
    Scripting/   ScriptValue, ScriptRunning, AppPresenceMonitoring, ScriptedPlayerProvider<Player>,
                 AppleMusicPlayer (+ AppleMusicPlayerInfo), SpotifyPlayer (+ SpotifyPlaybackEvent)
    Sources/     KnownApps (bundle IDs, incl. the "Search" browser com.officecommun.search), SourceResolver,
                 WebSiteInference (site guess for browser playback)
    Hub/         HubTypes (PlayerID, HubConfiguration, HubState, HubEvent, PlaybackExpectation), HubCore (pure rules),
                 NowPlayingHub (driver; a NowPlayingProvider itself), IntroSkipPolicy ("start at 0:15")
    Artwork/     ArtworkPipeline (+ ArtworkPolicy), ArtworkImage (decode, square crop, letterbox trim, digests),
                 ArtworkCaches (disk cache in ~/Library/Caches/Ahenk/Artwork, memory LRU, HTTPFetching)
    RecentlyPlayedStore (Continue Playing: 50 songs in ~/Library/Application Support/Ahenk/RecentlyPlayed.json)
  Catalog/     ITunesSearch (search, match scoring, artwork sizes), SpotifyOEmbed
  Color/       OKLab, PaletteExtractor (k-means in OKLab), Palette (+ onDark/onLight/vivid/backdrop)
  Bridge/      BrowserBridge protocol, BrowserTabReport, BrowserProvider (stub until Step 7), LocalPlaybackProvider (stub)
Sources/AhenkApp/NowPlaying/
  NowPlayingServices (builds and runs everything; observable state for Settings and menus),
  AdapterLocator (bundle; `swift run` falls back to Vendor/), AppleScriptRunner (NSAppleScript + AEDeterminePermission),
  RunningApps (+ BrowserRegistry, AppDirectory), MusicNotificationBridge, NowPlayingModel (follows the hub)
Tests/AhenkKitTests/          166 tests in 22 suites (was 76): hub rules and driver, adapter payloads/decoder/process
                              (fake /bin/sh adapters), scripted providers (fake runner and presence), palettes from
                              generated images, artwork pipeline (fake HTTP), catalog matching, Continue Playing
```

Data flow: providers → `HubInput` → `NowPlayingHub` (`HubCore`) → `NowPlayingModel` (song, cover,
lyrics, features for the UI) and `NowPlayingServices.state` (players, the followed one, the
conflict). Every published snapshot is offered to Continue Playing (`RecentlyPlayedStore`:
songs only, i.e. `.music` or `.unknown`, deduplicated, newest first, 50 kept); hub events
drive "start at 0:15".

| Provider (id) | Sees | Commands | Permission |
|---|---|---|---|
| `MediaRemoteProvider` (`mediaremote`) | whatever app owns the system Now Playing (one at a time) | adapter `send/seek/shuffle/repeat`, which reach that owner | none |
| `AppleMusicProvider` (`apple-music`) | `com.apple.Music.playerInfo` always; AppleScript reads with Automation (position, persistent ID, shuffle, repeat, favourite, raw artwork) | AppleScript | Automation |
| `SpotifyProvider` (`spotify`) | `com.spotify.client.PlaybackStateChanged` always (with position); AppleScript adds artwork URL, shuffle, repeat | AppleScript (no like, repeat on/off only) | Automation |
| `BrowserProvider` (`browser`) | nothing until Step 7 | the bridge | — |
| `LocalPlaybackProvider` (`local`) | nothing until Step 9 | — | — |
| `DemoProvider` (`demo`, `demo-b`) | invented songs | all | — |

Hub rules (`HubCore`, all unit-tested): reports that describe the same `PlayerID` (source +
owning app bundle + instance) merge, the music app's own provider first, the system report
filling a missing position/shuffle/artwork; automatic follows the player that started playing
most recently (a song change is not a start; a pause shorter than 2.5 s keeps the start time);
nothing playing keeps the last followed player; pinned follows only its source; ignored sources
are dropped; two or more players playing together for 3 s raise a `PlaybackConflict` (automatic
mode with "ask" on) shown in the menu bar menu with a dot on the icon; the answer is followed
until something else starts and, with "pause the previous source" on, the others are paused; a
followed player that goes quiet stays 1.2 s (no flash between songs); after a command the
expected state shows at once and holds 2 s or until the player confirms it; each command goes
to the most authoritative provider whose snapshot supports it. Snapshots are published only on
noticeable change (song, state, seek > 0.5 s, shuffle, repeat, like, artwork, commands).

### Build, run, verify

```sh
swift build && swift test             # 166 tests, no warnings
./Scripts/make-app.sh && ./Scripts/smoke.sh
open -n dist/Ahenk.app                # live: follows the system Now Playing, no prompts
open -n dist/Ahenk.app --args --demo-conflict   # two demo players → the question after 3 s
open -n dist/Ahenk.app --args --settings sources
```

New smoke checks (all `ok`): `adapterRun` (the bundled adapter answers `get` once; reports
only the kind of source, never the song), `sources` (bundle mapping, site inference, browsers
found), `hub` (rules on invented players), `nowPlaying` (demo through the hub: song, cover,
lyrics, features), `artwork` (generated 800 px cover → 600 px, ≥ 3 colours, text variants
≥ 4.5:1, offline), `recentlyPlayed` (dedupe and reload). `menus` also builds the conflict
question in both languages. `--smoke --snapshots` also writes `menubar-icon*.png`.

Live check on this Mac (read-only, 2026-11-08): with a paused video in the Search browser, the
normal launch followed it (`otherApp`, `com.officecommun.search`), Settings › Sources showed
"System Now Playing: Working" and Apple Music / Spotify "Not running"; no prompt appeared; the
adapter child exited with Ahenk. Idle (nothing playing): Ahenk 0.0 % CPU, ~75 MB; adapter
child 0.0 % CPU, ~26 MB.

### Decisions

- **Automation never prompts by itself.** Permission is read with
  `AEDeterminePermissionToAutomateTarget(askUserIfNeeded: false)` when the app is running
  (again on Ahenk activation, when Sources opens and every 2 min while not granted). Only
  **Allow Access…** in Settings › Sources asks (`services.requestAccess`); Step 11's
  onboarding should call the same. Without it, the apps' own notifications still give the
  song and play state, and commands go through the system's Now Playing when that app owns it.
- **Never launching Music or Spotify.** No script runs unless `NSRunningApplication` says the
  app runs (checked right before each run), and every script is wrapped in
  `if application id "…" is running then … end if`, which AppleScript evaluates without
  launching anything. Both apps ship a static `.sdef`, so compiling never launches them.
  Scripts run on one serial queue with `with timeout of 4 seconds`; -1743 marks the source
  denied and stops reading.
- **AppleScript, not ScriptingBridge.** NSAppleScript results are converted from typed Apple
  Event descriptors into `ScriptValue` (numbers stay numbers, so no locale-dependent decimal
  text), which keeps the parsing testable with fixtures and needs no generated headers.
- **Distributed notifications are delivered immediately** (`suspensionBehavior:
  .deliverImmediately`); AppKit otherwise holds them while Ahenk is in the background.
- **The adapter sees one player.** MediaRemote reports only the session owner, so the
  dedicated providers (and Step 7's bridge) are what make conflicts visible. The adapter runs
  `stream --micros` (artwork included), restarts with backoff (0.5 s → 30 s, then 60 s and
  health `unavailable` after 5 silent failures) and is terminated in
  `applicationWillTerminate`. A child process reports its exit only after its output was read
  to the end.
- **Site guessing is conservative.** Browsers do not say which page plays; a site is named only
  from explicit markers (a " - YouTube Music"-style title suffix, a host name, the brand as the
  artist). Otherwise the player is `otherApp` with the browser's name and a content kind from
  the metadata (wide thumbnail → video; artist + album → music).
- **One song, two names.** Providers identify songs differently (a persistent ID, an adapter
  identifier, a metadata key), so `isSameTrack` = same source and (same id or same normalized
  title/artist with compatible album and duration ±3 s). Folding is locale-neutral and maps the
  Turkish ı to i.
- **Artwork.** Order: bytes from the source, the cover URL, Spotify oEmbed by track ID (640 px
  variant), then Apple's catalog when the cover is smaller than 90 % of the requested size (or
  missing) and the policy allows it (music only; never videos, podcasts, adverts, demo or
  local). Catalog matches need equal core titles and artists and a duration within 8 s. Misses
  are remembered 3 days, failures not at all. The chosen cover is also stored under
  `ArtworkPipeline.coverKey(for:)` for Continue Playing. Non-square images lose letterbox
  bars and are cropped square.
- **Palettes in OKLab**: k-means (k = 8, fixed seed) on ≤ 48 × 48 px, colourful clusters by
  area first, greys last, padded to 3 with shades. `onDark`/`onLight` reach 4.5:1 by moving
  only lightness; `vivid` lifts colours for light. `Palette` encodes only `colors`.
- **Shared API changes** (all call sites and tests updated): `NowPlayingSnapshot` gained
  `processIdentifier`, `instanceIdentifier`, `isPositionKnown`, `capabilities`, `contentKind`,
  `artworkData`, `artworkIdentifier` (all defaulted) and `differsNoticeably`;
  `isSameTrack` now falls back to metadata; `Palette.colors` is a `let`; `ArtworkProvider`
  gained `artwork(for: NowPlayingSnapshot, …)` with a default; `DemoProvider.init` takes
  `id` and `bundleIdentifier`; `LaunchOptions.demoConflict` (`--demo-conflict`).
- **Settings window title** is "Ahenk Settings" / "Ahenk Ayarları" (follows the language);
  SwiftUI's title bridging never set it, so it is set on the NSWindow directly.

### For Step 3 (audio engine)

- **What to tap:** the followed player is `environment.nowPlaying.snapshot` (main actor,
  observable) or `environment.services.hub.snapshots()` (any thread). Use
  `snapshot.bundleIdentifier`: the owning app (`com.apple.Music`, `com.spotify.client`, or the
  browser: `com.officecommun.search`, `com.google.Chrome`, `com.apple.Safari`, …).
  `processIdentifier` is the process that published Now Playing (the app for Music/Spotify,
  the browser's main process for Chromium); resolve audio processes at tap time, PIDs churn.
  Chromium plays audio from helper processes (match by bundle-ID prefix plus ancestry, as in
  DynamicIsland's `AudioProcessResolver`); Safari plays from `com.apple.WebKit.GPU`, which is
  shared by every WebKit app and is not a child of Safari.
- **When to listen:** `snapshot.isPlaying`, and only music: react to `contentKind == .music`
  (consider `.unknown` too: unlabelled players are mostly music); `.video`, `.podcast`,
  `.advertisement` must not move the light. Hub events (`.playbackChanged`,
  `.trackChanged`, `.activePlayerChanged`) say when to retarget the tap.
- `services.features` is `nil` in live mode (the demo's in `--demo`); plug the engine's
  `AudioFeatureSource` there and pass it to `nowPlaying.attach` in `AppDelegate.startServices`.

### For later steps

- **Step 5:** `hub.perform(_:)` / `perform(_:on:)` (respect `snapshot.capabilities`),
  `services.choose(_:)`, `hub.pausePlayers(except:)` for the source picker; Continue Playing
  from `services.recentlyPlayed.changes()`, covers from `ArtworkPipeline.storedCover(for:)`;
  `ITunesSearch` is ready for albums and search; `services.displayName(for:)` names players.
- **Step 6:** `services.lyrics` is `nil` in live mode; put the lyrics chain there.
- **Step 7:** implement `BrowserBridge` and pass it to `BrowserProvider(bridge:)` in
  `NowPlayingServices.live`. Tabs are players (`instance` = tab ID). The adapter's guess for
  the same song has another `PlayerID` (e.g. `otherApp` in the same browser), so while the
  bridge reports a browser, drop the adapter's reports for that browser, or the hub will see
  two players and ask. Replace the "browser does not say which site" footnote.
- **Step 9:** `LocalPlaybackProvider` is the stub to fill; covers for `.local` come from file
  metadata (the catalog policy skips them).

### Known gaps and risks

- Apple Music and Spotify scripting are verified with fixtures only: no Automation grant
  exists on this Mac and the rules forbid prompting. First real use: open Music or Spotify,
  Settings › Sources › Allow Access…, then check the log (`[apple-music]`, `[spotify]`).
- With the adapter alone, two players in browsers (or a browser and another app) cannot be
  seen at once: no conflict question until Step 7.
- Browser playback mostly shows as the browser's name (`otherApp`) until Step 7.
- MediaRemote has no "unlike" (only like/ban); Spotify has no like at all.
- A catalog cover can belong to another release of the same song (same title, artist and
  length).
- The status item is drawn by the system, so its badge cannot be captured with `winshot`;
  `--smoke --snapshots` exports the icons instead.
- If Ahenk is killed with SIGKILL, the adapter child lives until its next write fails
  (SIGPIPE).

### Deviations from PLAN.md

- ScriptingBridge is not used (AppleScript through NSAppleScript; see Decisions).
- Extra launch argument `--demo-conflict`; extra folders `NowPlaying/{MediaRemote,Scripting,Hub,
  Sources,Artwork}`, `Catalog/`, `Bridge/` in AhenkKit.
- The menu bar shows the current song in the menu (title, "artist · source", cover); the
  title next to the icon still follows `general.showSongTitleInMenuBar`.

## Step 3 — Audio analysis (done, 2026-11-09)

### What exists

```
Sources/AhenkAtomics/         C target: acquire/release loads and stores, fetch-add, a seqlock (static inline)
Sources/AhenkKit/Audio/
  AudioFeatures              the contract: energy, AudioBands (5), spectrum (SIMD32), onset, beat, beatPhase,
                             beatIndex, bpm, tempoConfidence, isSilent; AudioFeatureSource (+ features(at:)); AudioClock
  AudioRingBuffer            single-producer/single-consumer ring of mono samples (I/O thread → analysis queue)
  SeqlockBox, AudioFeatureStore (+ AudioFeatureFrame, activity observation)
  AudioAnalysisPipeline      ring → analyzer → store: music gate, sensitivity, presentation delay, digital-silence meter
  SyntheticSignal            kick trains, a kick/snare/hat pattern, sines, seeded noise (tests and --smoke)
  Analysis/                  AudioAnalyzer, BandLayout, TempoEstimator, BeatTracker, Envelopes
  Capture/                   AudioCapturePolicy (+ AudioCapturePermission, AudioTapTarget, AudioTapRequest,
                             AudioCaptureState), AudioProcessMatcher (+ AudioProcess)
Sources/AhenkKit/Demo/DemoAudioSynth   the demo's 120 BPM beat as sound (pure function of the song position)
Sources/AhenkApp/Audio/
  AudioTapEngine             main-actor façade: store, ticker, permission, status; owned by AppEnvironment (`audio`)
  AudioCaptureController     the policy and every HAL call on a control queue; a 100 Hz pump on an analysis queue
  ProcessTapSession          CATapDescription + private aggregate device + a C IOProc (mono mixdown into the ring)
  CoreAudioQueries           process list (PID, bundle, responsible PID, parents), devices, output latency
  SystemAudioPermission      TCC preflight (silent) and request (button only), System Settings link
  AudioFeatureTicker         display-link publisher for UI on the main thread; DemoAudioFeed (synth → ring)
Sources/AhenkApp/Settings/AudioMonitorView   Settings › Sound monitor (Core Animation layers)
Tests/AhenkKitTests/          220 tests in 29 suites (was 166/22): analyzer, ring, store, pipeline, policy, matcher
```

Data flow: process tap IOProc (Core Audio's real-time thread) → `AudioRingBuffer` → analysis
queue pump every 10 ms → `AudioAnalyzer` → `AudioAnalysisPipeline` (host clock, gate, sensitivity,
output delay) → `AudioFeatureStore` (seqlock) → any reader: `services.features`,
`nowPlaying.featureSource`, `audio.store` are the same object. `--demo`/`--smoke` replace the tap
with `DemoAudioFeed` (the synth at real-time pace into the same ring); no permission involved.

### Build, run, verify

```sh
swift build && swift test             # 220 tests, no warnings
./Scripts/make-app.sh && ./Scripts/smoke.sh
open -n dist/Ahenk.app --args --demo --settings sound     # live monitor on the demo beat
open -n dist/Ahenk.app --args --settings sound            # live: permission row, Allow Listening…
```

BPM/beat tests (`AudioAnalyzerTests`): "Kick trains: tempo within ±2 BPM and every beat within
±50 ms" (70, 90, 120, 128, 140, 174 BPM at 48 kHz; measured: within 0.3 BPM, beats within ~5 ms),
"A kick + snare + hi-hat pattern reads as its quarter notes" (95, 120, 150), "The tempo is the same
at 44.1 kHz and 96 kHz", "The demo synthesizer reads as 120 BPM on the beat", "Kicks under noise
still lock to the tempo", "Kicks trigger beats before the tempo is known". Silence and bands:
"Silence turns isSilent on within the gate time and sound turns it off at once", "A low sine
lights the low bands, a high sine the high band", "A steady tone has no tempo and no beats",
"White noise does not produce a beat storm" (≤ 4 beats in 16 s, none predicted, no tempo).
Ring buffer: "Writes and reads wrap around the end in order", "One writer thread and one reader
thread pass every sample in order". Store: "Readers on other threads never see a torn frame".

New smoke check `audio`: a 120 BPM kick train reads as 119.9 BPM with settled beats within 3 ms;
10 s of audio analysed in 6 ms (~1500× real time); silence gates; an 8 kHz sine lights `high`;
the demo beat passes ring → pipeline → store; the permission is read without a prompt
(`notDetermined` on this Mac). `nowPlaying` now waits for live features from the analyzed demo beat.

Measured on the M5 (release build): live, nothing playing: **0.0 % CPU**, ~75 MB (no tap, no timer,
no listener); `--demo` without a window 1.3 % (synth ~0.6 %, analysis ~0.3 %; a real tap has no
synth); `--demo` with Settings › Sound open 2.6 % (the monitor was 12 % when drawn with
CoreGraphics/CoreText per frame; Core Animation layers brought it to ~1 %).

### For Step 4 (edge light)

- **Reading per frame.** Keep `environment.audio.store` (or `services.features`) as
  `any AudioFeatureSource` and call `features(at: targetTimestamp)` once per rendered frame from the
  render thread, with the display link's target timestamp (`AudioClock` = the
  `CACurrentMediaTime()` / `CADisplayLink.targetTimestamp` base); `currentFeatures()` reads "now".
  Lock-free (a two-slot seqlock; readers never wait, even if the writer is preempted),
  allocation-free, ~1 µs. `beat` and `beatPhase` are computed at the moment you ask, so they are
  smooth at 60 or 120 Hz although frames are published every ~10 ms.
- **Values** (all smoothed already; do not smooth again unless you want slower motion):

  | Field | Range | Meaning, smoothing |
  |---|---|---|
  | `energy` | 0…1 | loudness on an adaptive 24 dB window (typ. 0.6–0.9 in music); attack 25 ms, release 220 ms |
  | `bands.subBass/bass/lowMid/mid/high` | 0…1 | 20–60, 60–250, 250–500, 500–2k, 2k–16k Hz on one shared 30 dB reference (a bass line lights `bass`, a hat `high`); 15/160 ms; `bands.packed` = SIMD8 for a shader |
  | `spectrum[0..<32]` | 0…1 | log bands 30 Hz–16 kHz (+4.5 dB/oct display tilt), 42 dB window; 10/110 ms |
  | `onset` | 0…1 | attack flash (kick, snare, pluck); instant attack, 70 ms release |
  | `beat` | 0…1 | the beat's strength (0.4–1) at the beat, then `exp(-t/τ)`, τ = 0.25 × beat length clamped to 70–200 ms (120 ms while unlocked) |
  | `beatPhase` | 0..<1 | position in the beat (0 on it); 0 while the tempo is unknown |
  | `beatIndex` | Int | +1 per beat, never reset (not even by silence or a new song): `beatIndex != last` is a new beat |
  | `bpm` | 0 or 60…200 | 0 until locked (~2.5 s into a song) |
  | `tempoConfidence` | 0…1 | ≥ 0.35 locked: beats are predicted on the grid (announced 30 ms early, phase-corrected by onsets); below that, beats come from kicks |
  | `isSilent` | Bool | every level and `beat` are exactly 0 |

- **Silence and play state.** `isSilent` turns true at once when the followed player pauses or
  plays something that is not music (the engine closes its gate on the hub event), and ~0.35 s
  after the sound stops otherwise. Fade out on it (with `nowPlaying.isPlaying` as a hint), then stop
  your display link. To wake without polling, observe `store.observeActivity { active in … }`
  (called on the analysis queue when silent ↔ active) or subscribe to `audio.ticker`, which already
  sleeps while silent.
- **Timing is already compensated.** Frames are delayed to the default output's latency (Bluetooth
  headphones: 100–250 ms) and predicted beats are announced 30 ms early, so
  `features(at: targetTimestamp)` lands on the sound; do not add your own offset.
- **Sensitivity** (Settings › Sound) is already applied (levels × gain, clamped to 1).
- **Demo.** `--demo` features are the analyzer's view of `DemoAudioSynth` (120 BPM, locks after
  ~2.5 s, real-looking spectrum). For exact offscreen frames use `DemoBeat.features(at:)` as
  `MetalProbe` does. `MetalProbe` passes `features.energy` as the shader's `level`.
- **UI at display rate** (main thread): `environment.audio.ticker.subscribe(framesPerSecond:) { f in … }`
  — one display link for all subscribers, paused while silent; keep the returned subscription.
  Do not drive SwiftUI per frame (Step 1); use leaf AppKit/Core Animation views like
  `AudioMonitorView`.

### Decisions

- **Atomics in C.** `Synchronization.Atomic` needs macOS 15; the `AhenkAtomics` target wraps the
  compiler's builtins (`__atomic_*`) in static inline functions, imported `internal` by AhenkKit.
- **Real-time path.** The IOProc is a C function whose context holds only raw pointers (the ring's
  writer view and a scratch buffer): no locks, no allocation, no ARC. It averages every channel of
  every buffer to mono with vDSP and writes to the SPSC ring (drops and counts on overflow). The
  analysis queue pumps every 10 ms only while a tap or the demo feed runs.
- **Analysis.** Hann window ~43 ms (2048 at 44.1/48 kHz, 4096 at 88.2/96 kHz), hop a quarter
  window (~10.7 ms, ~94 frames/s); vDSP real FFT, power normalized so a full-scale sine is 0 dB.
  Levels are drawn on adaptive dB windows (fast up, ~1 dB/s down, held through silence). Onsets:
  spectral flux of the floored band levels with an adaptive threshold and one frame of look-ahead
  (onset latency compensated, calibrated on kick trains). Kicks: a 40–150 Hz rise ≥ 6.5 dB that
  also lifts the whole spectrum (noise rarely does). Silence gate: below −60 dBFS for 0.35 s, open
  above −54 dBFS; 2.5 s of silence forgets the tempo; a new song (hub `trackChanged`) does too.
- **Tempo without octave errors.** Every tempo 60–200 BPM (0.5 BPM steps, parabolic refinement)
  lays its beat grid over the last 8 s of the onset envelope at its best phase; score =
  explained share of onset peaks × fill² (grid points that hit an onset; weaker beats of an accent
  pattern still count, empty points do not) × a one-octave preference around 120 BPM. Confidence =
  how far the winner stands out from the average candidate. The tracker locks at ≥ 0.35, follows
  small tempo changes, needs three agreeing estimates for a new tempo, re-phases after two misses,
  unlocks after ~2 s of low confidence.
- **Whose sound.** `AudioProcessMatcher`: the app's PIDs and bundle, processes the app is
  responsible for (`responsibility_get_pid_responsible_for_pid`, looked up at run time; this is
  how WebKit's GPU process, which plays Safari's and the Search browser's audio, is found),
  descendants (Chromium/Electron/Firefox helpers) and the publishing PID; never by name
  similarity, never Ahenk. Resolved anew on every change and whenever the process list changes.
- **Fallbacks.** Nothing found for 2.5 s, or 3 s of digital silence while the player plays (looked
  up again once) then 6 s → a tap on everything but Ahenk's processes, until the player changes.
  A failed build backs off 2/5/15/30 s. A tap that stops delivering for 2 s is rebuilt.
- **Microphone safety.** The aggregate device is clocked by the default output only if it has no
  input streams; otherwise by an output-only device (built-in speakers first). A device with a
  microphone never joins Ahenk's aggregate, so starting it can never start a microphone.
- **Taps are private and unmuted** (`isPrivate`, `muteBehavior = .unmuted`); the music is never
  silenced, nothing is recorded or saved; the samples live in the ring until analysed.
- **Music only.** The gate opens for `.music` and `.unknown` content (except on YouTube); videos,
  podcasts and adverts never move the light. Pausing closes the gate at once; the tap stays 8 s
  (no rebuild for a short pause), then everything stops.
- **Permission.** TCC's preflight (silent) is read at launch, on activation, when Settings › Sound
  appears and when the menu opens; TCC's request is called only by **Allow Listening…** (Settings ›
  Sound, and the menu bar menu while not asked yet: the first-run hint). Denied → "Open System
  Settings…" (`Privacy_AudioCapture`). Turkish strings use macOS's own names for that pane.
- **Presentation delay** = the default output's latency (device + stream latency, safety offset,
  buffer), clamped to 0.5 s; frames wait in a 64-frame queue until heard.

### Deviations from PLAN.md

- Extra C target `AhenkAtomics` (see Decisions).
- **Shared API changes** (all call sites and tests updated): `AudioFeatures` reshaped
  (`level` → `energy`; `bass/mid/treble` → `bands: AudioBands` with five bands; `bands: SIMD16` →
  `spectrum: SIMD32`; new `tempoConfidence`; `bandCount` → `spectrumCount`);
  `AudioFeatureSource.features(at:)` added with a default; `NowPlayingServices.live/demo` take
  `features:`; `AppEnvironment.audio` added. `DemoProvider` still answers `currentFeatures()` with
  `DemoBeat` (tests), but the app's demo features now come from the analyzed synth.
- The "first-run hint" is the menu bar menu item (onboarding is Step 11; it should call
  `environment.audio.requestPermission()`).
- macOS 26's `CATapDescription.bundleIDs` / `processRestoreEnabled` are not used: one code path
  (process objects + a process-list listener) for 14.2 and later.

### Known gaps and risks

- **No real tap has run on this Mac.** Ahenk's system audio permission is "not asked yet" and the
  rules forbid triggering the prompt, so `ProcessTapSession` (ported from DynamicIsland's working
  tap), the listeners and the latency read are verified only up to compiling and the smoke
  checks. First real use: press **Allow Listening…**, play a song, and check the log
  (`[audio] Listening to com.spotify.client (1 process), 48000 Hz, output latency … ms`) and the
  monitor in Settings › Sound.
- The TCC and responsibility functions are private API looked up at run time. If TCC's go away the
  state reads "unknown" and the user must press Allow Listening… after every launch (that choice is
  not stored).
- Tuned on synthetic patterns: real songs with a half-time feel may lock at half or double tempo
  (then the pulse comes every other beat or twice per beat); `onset` and kicks still follow the
  drums.
- The fallback tap on everything hears other apps too (a notification, a video elsewhere).
- When the default output has a microphone (a USB headset), the tap is clocked by another output
  device; whether it then still hears audio routed to the headset is untested.
- Chromium starts its audio-service process when playback starts; until the process-list listener
  sees it, the tap waits (up to 2.5 s before the fallback).
- The output latency comes from the HAL; some Bluetooth devices may report it wrong (the delay is
  clamped to 0.5 s).

### What the user must do once

Open Ahenk normally (`open -n dist/Ahenk.app` or the installed app), play music, then press
**Allow Listening…** in Settings › Sound (or in the menu bar menu) and allow it in macOS's dialog.
If it was denied: System Settings › Privacy & Security › Screen & System Audio Recording › System
Audio Recording Only › turn on Ahenk. The grant survives rebuilds (stable signing identity).

## Step 4 — Edge light (done, 2026-11-09)

### What exists

```
Sources/AhenkKit/Light/
  EdgeShape            a display's outline: corner radii (notched MacBook panels round their top corners, 10 pt;
                       6 pt minimum elsewhere), the notch (from the menu bar's auxiliary areas)
  EdgeGeometry         EdgeMetrics (band depth, perimeter coordinate radius, wrap, corner arm), EdgeField (the shader's
                       distance, perimeter coordinate and masks in Swift), EdgeLayout (the strips per position)
  EdgeAtlas            a screen's strips packed into one surface: shelves, tall strips turned, transparent gutters
  LightLook            the look from the settings (line, halo, band, preview scale); shader numbers of styles/positions
  LightFade            fades: music (in 0.8 s, out 1.6 s), presence of one display (in 0.6 s, out 0.45 s)
  LightFramePolicy     60 fps full / 30 fps light at half resolution / paused, from power state and visibility
  LightColors          four colour slots (album vivid palette, custom, rainbow) + PaletteCrossfade (OKLab, 1.5 s)
  LightMotion          drift clock, travel (kicks push it), loudness swell, the last four beats (+ made-up soft beats)
  EdgeLightUniforms    the 432-byte uniform struct, every offset checked against the compiled shader
  EdgeLightRenderer    device, queue, library, pipeline per pixel format; strip and atlas passes; offscreen float images
Sources/AhenkApp/Light/
  EdgeLightController  every input → per-screen state; status for Settings (`environment.light`)
  EdgeLightOverlay     EdgeLightWindow (one per display) + its strip layers
  EdgeLightRenderLoop  render thread, one display link per screen, one atlas pass and one CA transaction per frame
  SurfaceRing          three IOSurfaces a screen's atlas is drawn into in turn
  LightScreen          NSScreen → UUID, name, frame, shape, refresh rate
  DesktopWatcher       frontmost app ("only on the desktop") and full-screen displays
  LightPreviewView     the Settings gallery's live tiles + LightPreviewClock (one 30 fps link while visible)
  EdgeLightCheck       the smoke checks; MetalShaders (+ EdgeLightShader: the shared renderer, compiled once)
Sources/AhenkApp/Support/PowerMonitor    battery (IOPS notification), Low Power Mode, thermal state (`environment.power`)
Sources/AhenkApp/Resources/Shaders/EdgeLight.metal   geometry + 22 styles (runtime-compiled, ~100 ms cold)
Tests/AhenkKitTests/          258 tests in 36 suites (was 220/29): geometry, atlas, fades, frame policy, colours,
                              motion, uniforms vs shader reflection, offscreen renders of every style and position
```

Styles (`LightStyle`, shader number in brackets): Soft Glow [0] halo flowing in the cover's colours with fine
sparkles (the default, as in the reference videos); Pulse [1] every beat flashes the edge in the next colour and
sends a ring inwards; Breathe [2] one colour, slowly breathing; Wave [3] the inner edge rolls in waves that kicks
send on; Spectrum [4] 32-band bars, bass at the bottom middle, treble at the top; Snake [5] a comet with a white-hot
head; Twin Snakes [6] two comets that flare where they meet; Lava [7] molten blobs; Aurora [8] folded curtains with
faint rays; Rainbow [9] concentric rainbow stripes; Neon Tube [10] a glass tube per side with bends and flicker;
Plasma [11]; Fire [12] flames in the cover's warmest colour; Embers [13] rising sparks; Snow [14] flakes that settle
on the bottom edge; Hearts [15] upright hearts that beat; Fireworks [16] a burst per beat; Sparkles [17] four-point
stars; Bubbles [18]; Lightning [19] a bolt per beat; Rain [20] slanting streaks with splashes; Starfield [21] stars
streaming out, warping on kicks.

Data flow: settings, `nowPlaying` (playing music, cover palette), `audio.store.observeActivity`, `power`, screens,
`DesktopWatcher` → `EdgeLightController` (main) → per-screen `EdgeLightScreenState` → `EdgeLightRenderLoop` (render
thread): display link tick → `features(at: targetTimestamp)` → `LightMotion`, `LightFade`s, `PaletteCrossfade` →
uniforms per atlas slot → one render pass into a `SurfaceRing` surface → wait for the GPU → one CA transaction sets
that surface on every strip layer (each shows its slot through `contentsRect`, turned slots turned back).

### Build, run, verify

```sh
swift build && swift test             # 258 tests, no warnings
./Scripts/make-app.sh && ./Scripts/smoke.sh
./Scripts/smoke.sh --snapshots        # also light-<style>.png: each style at three moments of the demo beat
AHENK_LIGHT_PREVIEW_DIR=/tmp/light swift test --filter EdgeLightRenderTests   # PNGs from the render tests
open -n dist/Ahenk.app --args --demo                      # the light around every screen
open -n dist/Ahenk.app --args --demo --demo-pause-after 4 --demo-resume-after 18   # fade out, stop, come back
open -n dist/Ahenk.app --args --demo --settings light     # the gallery
```

Smoke checks: `metal` (compile the bundled shader, every uniform offset equals the shader's reflection, 432
bytes) and `edgeLight` (22 styles × 3 moments + 3 positions rendered offscreen into float targets: finite, real light,
nothing outside the band, ~300 ms; then a light window for the main screen is built but never shown and one frame
is drawn into its atlas and set on its strip layers) and `lightSwitch` (the real controller runs with every display
switched off in the in-memory settings, so nothing appears; the menu bar's Edge Light item turns it off and on and
its status follows).

Measured on the M5 (release build, demo, Soft Glow, one 1512 × 982 notched display, load average ~2.6): light on
at 60 fps 5.1–5.5 % CPU for the whole app vs 1.25–1.5 % with the light off, so **the light costs ~3.9 %** (Fire
~4.4 %); Optimized Mode (30 fps, half resolution) ~1.8 %; **after a pause 0.00 %** (the fade-out ends 1.6 s after
the pause, then no display link, no timer). Settings › Edge Light open with the gallery adds ~2 %. Memory: footprint
77 MB with the light running (13 MB light off, 35 MB after the pause). The four strips cover 22 % of the screen (the
top strip includes the notch).

### Decisions

- **Draw only the band, in one atlas, through IOSurfaces.** Each screen's light lives in a few strips along the
  edges (`EdgeLayout`), never a full-screen layer. The strips started as one `CAMetalLayer` each: ~8 % CPU at 60 fps,
  mostly per-drawable presentation bookkeeping (frame pacing, shared events, presented callbacks), which a constant
  frame did not trigger (4.0 %). Plain layers showing IOSurfaces brought it to ~5 %; drawing all strips into one
  atlas surface in one render pass, shown on every strip layer in one transaction, to ~3.9 %. The render thread
  waits for the GPU (~1 ms) before swapping, so the window server never shows a half-drawn surface; a ring of three
  surfaces skips a frame if all are still on screen. `contentsRect` counts y from the bottom of the image; a turned
  slot's row starts at the strip's bottom end and its top edge is the strip's left edge (measured, and covered by
  the atlas render test).
- **A render thread.** One thread with a run loop carries every screen's display link and all encoding, so a busy
  main thread (SwiftUI re-laying out Settings) never makes the light stutter. The main thread only sends state; the
  thread reports a screen that finished fading out, and the main thread then orders its window out.
- **Window level: right below the Dock** (`CGWindowLevelForKey(.dockWindow) - 1`): above every app window as the
  plan asks, but under the Dock, the menu bar, menus and alerts, so their text stays readable over the glow (the
  Dock's and the menu bar's glass blur the light behind them). `.canJoinAllSpaces`, `.stationary`, `.ignoresCycle`;
  `.fullScreenAuxiliary` only when the light should not step aside for full-screen apps.
- **Full screen:** native full-screen Spaces never show the window unless `.fullScreenAuxiliary` is set; borderless
  "full-screen" windows (games, slideshows) are caught by `DesktopWatcher`, which compares on-screen windows' bounds
  with the displays (CGWindowList: bounds, owners and layers only, no window contents, no permission) on app
  activation and Space changes, once more 0.8 s later. **Only on the desktop** = the Finder or Ahenk is the active
  app (Ahenk too, so the light shows while its settings are changed).
- **When it shines:** music the light reacts to (`AudioCapturePolicy.reactsTo`: music, or unlabelled content except
  on YouTube) is playing per the hub, or the analysis hears sound. Without the system audio permission the light still
  shows while music plays, drifting, with made-up soft beats every ~1.9 s; videos and podcasts never light it.
- **Changes show themselves.** Changing how the light looks (style, position, line, glow, intensity, speed, colours,
  displays) while nothing plays shows it for 3.5 s with the demo beat; turning it on does too.
- **Geometry.** No API gives a panel's corner radius: notched built-in displays get 10 pt top corners (MacBook panels
  are rounded at the top), every corner at least 6 pt; the notch's lower corners are 30 % of its height and a 6 pt
  smooth minimum rounds the junction with the top edge, so the light wraps the notch. The perimeter coordinate uses a
  corner radius of at least the band (no seam on the corner diagonals); particles are placed in that coordinate's own
  (polar) frame or at true screen points (`outlinePoint`), so they stay round and upright in corners. Patterns along
  the edge use whole numbers of periods per lap and noise blends across the coordinate's seam; `travel` wraps at one
  lap (only integer multiples are used), `drift` at 4096 s.
- **Colours:** the album palette's `vivid` variants in four slots (1 → aaaa, 2 → abab, 3 → abcb), crossfaded in OKLab
  over 1.5 s; the last palette stays while a new song's cover loads. Output is premultiplied with colour slightly
  above alpha, so the light brightens what is under it.
- **Previews:** the gallery tiles are AppKit views driven by one 30 fps display link that runs only while a tile is on
  screen (window occlusion) and scrolled into view, at one pixel per point, through the shared renderer
  (`EdgeLightShader.shared`, compiled once off the main thread); SwiftUI never re-renders per frame.

### Deviations from PLAN.md

- AhenkKit now imports Metal (no AppKit): `EdgeLightRenderer` lives there so the tests can render every style
  offscreen against the real shader (loaded from the repository path). The app loads the same source from its bundle.
- No `CAMetalLayer`/`MTKView` on screen: strips are plain layers showing IOSurfaces (see Decisions), for CPU.
- The light sits below the Dock and the menu bar (still above every app window).
- Extra launch arguments `--demo-pause-after <s>` and `--demo-resume-after <s>`.
- **Shared API changes** (call sites and tests updated): `MetalProbe` and the app's 64-byte `EdgeLightUniforms` are
  gone (AhenkKit's `EdgeLightUniforms` replaces it); the smoke check `metal` now compiles and compares the layout, and
  `edgeLight` is new; `AppEnvironment` gains `power` and `light`; `LaunchOptions` gains `demoPauseAfter` and
  `demoResumeAfter`; `LightPane` takes the controller.

### For Step 5 (desktop player)

- **Levels:** the light's windows are at Dock − 1, above the desktop widgets you will add (just above the desktop
  icons). A widget at a screen edge gets the glow over it; that is intended.
- **Colours:** `environment.light.colors` (`LightColors`, four slots) is what the light draws with right now; for
  the player use `nowPlaying.artwork?.palette` (`onDark`/`backdrop` for text and glass) so both match the cover.
- **Power:** `environment.power` (battery, Low Power Mode, heat) is started by the app delegate; follow
  `LightFramePolicy`'s pattern (lighter on battery/Optimized Mode/heat, nothing when hidden).
- **Live visuals:** draw them as AppKit/Core Animation leaf views; if one needs Metal, reuse
  `EdgeLightShader.shared.renderer.device` and prefer IOSurface contents over a `CAMetalLayer` for small, always
  animating layers (measured above).
- **Play/pause:** the light follows the hub by itself (playing music → fade in; pause → fade out and stop), so player
  commands need no light code. `--demo-pause-after` / `--demo-resume-after` exercise the transitions without UI.
- **Only on the desktop:** clicking a desktop widget makes Ahenk the active app, which counts as "the desktop", so
  the light stays on.

### Known gaps and risks

- Tested on one display (the built-in, notched one). Several displays, hot-plugging and resolution changes are
  handled (`didChangeScreenParametersNotification` rebuilds windows and display links) but were not tried on hardware.
- The 10 pt panel radius is an estimate (no API); it looks right on this Mac.
- Full-screen stepping aside was not tried live (it would take over the user's screen): native full-screen Spaces rely
  on the collection behaviour, borderless full-screen windows on the bounds check.
- "Only on the desktop" counts the Finder as the desktop even while Finder windows are open.
- No real tap has run (as in Step 3): with real music and no permission the light drifts with made-up beats; it
  follows the real beat after **Allow Listening…**.
- CPU numbers vary by ±0.5 % between runs on this busy Mac.
- A settings change lays out the strip layers on the main thread while the render thread swaps their contents; one
  frame may show the old layout.
- `waitUntilCompleted` on the render thread: a stuck GPU would stall the light (not the app).
- The gallery's tiles cost ~2 % CPU while Settings › Edge Light is visible.

## Step 5 — Desktop player (done, 2026-11-09)

### What exists

```
Sources/AhenkKit/
  Catalog/     CatalogModels (artists, albums, songs, playlists, MusicCatalog), ITunesCatalog (search, artist of a song,
               albums, album songs, top songs; cached, shared in flight, throttled), CatalogCache, RequestThrottle,
               SpotifyTrackFinder (ListenBrainzSpotifyFinder: Spotify track IDs by title/artist/album, batched)
  Demo/        DemoLibrary (6 invented artists, their albums/EPs/singles, 4 playlists, invented lines) + DemoMusicCatalog;
               DemoProvider plays any library song alone after a start delay and keeps a volume
  Player/      PlayQueue (+ SongMatching), QueueConductorPolicy (+ PlaybackAttempt), PlayerScripts (Music and Spotify
               AppleScript: play by ID or name, playlists, volume), WidgetPlacement (+ DesktopWidget), CoverFlowGeometry,
               ClockText, PlayerLayout (window sizes, queue panel place, ProgressSchedule, ListeningSourceChoice)
  Bridge/      BrowserPlaybackRouting (+ BrowserPlayRequest/Outcome): what Step 7's extension implements
Sources/AhenkApp/Desktop/
  DesktopPlayerController   the widget windows on the chosen display: placement, saved places, grow/shrink, the queue
                            panel, occlusion, screens, keyboard for the search field
  DesktopWidgetWindow       non-activating panel one level above the desktop icons (+ DesktopHostingView, WidgetMover)
  DesktopPlayerModel        what the widgets show and do (theme, lists, albums, pages, search, volume, status)
  QueueConductor            plays Ahenk's queue in a source that knows one song at a time (+ PlayerStatus)
  PlaybackRouter            plays a pick in the demo, Music, Spotify or (Step 7) a site; playlists and volume
  CoverImageStore           covers at the size shown (catalog, generated, stored), memory + ~/Library/Caches/Ahenk/Covers
  DemoStage                 --demo-backdrop (generated wallpaper window) and --demo-scene
  Views/                    ClockWidget, ContinuePlayingWidget, PlayerWidget, CoverFlowView, PlayerBar (source picker,
                            transport, song, actions, volume slider, status toast), SearchField, PlayerPages (search
                            results, album, artist), QueuePanel (+ QueueList), ProgressLine, WidgetStyle
Sources/AhenkApp/Settings/Panes/PlayerPane   show/hide each widget, size, display, clock date/format/size, where picks
                            play, start at 0:15, Reset Layout
Scripts/widget-shot.swift   captures only Ahenk's windows (ScreenCaptureKit), for checks and screenshots
Tests/AhenkKitTests/        315 tests in 51 suites (was 258/36): catalog decoding, ListenBrainz decoding, throttle, demo
                            library, play queue, conductor rules, Music/Spotify scripts, placement and clamping, cover
                            flow index math, clock text, window layout, progress pacing, listening source, launch options
```

The widgets (default layout): the clock with the date at the top left, Continue Playing under it, and the player in the
lower middle (moved right of the list when they would overlap): the cover flow of the playing artist's albums (the playing
album in the centre with its title and "2025 · Album"), the search field with round buttons (Clear Desk when Step 9 makes it
available, small player), and the player bar. Clicking the centre cover opens its songs (its play button plays it); a side
cover comes to the centre; drag, swipe or scroll to browse. Search shows artists, songs (eight, "Show All") and albums;
artist and album pages open above the field with Back and Close; right-click on any song: Play Next, Add to Queue, Go to
Album; Return plays the first song; Esc empties the field. The bar: source picker (a coloured badge; its menu chooses where
picked songs play, Automatic follows what plays), shuffle, previous, play/pause, next, repeat (with Ahenk's queue they act on the
queue), cover, title, "artist — album", a thin line (click or drag to seek), More (album, artist, size, Reset Layout,
settings, hide), lyrics (flips `settings.lyrics.enabled`; Step 6 draws them), queue, like (when the source has it) and
volume (an inline slider, when the source's volume can be read). The list's title is a menu of the source's playlists; its
round button plays the whole list or pauses it. The small player is the bar with round buttons above it (search, Clear
Desk, large). While a song starts, the bar shows it with "Starting…", a pulse on the cover and a light along the line.

### Build, run, verify

```sh
swift build && swift test             # 315 tests, no warnings
./Scripts/make-app.sh && ./Scripts/smoke.sh --snapshots   # desktop-*.png: every widget and page in both languages
open -n dist/Ahenk.app --args --demo                      # the player on the desktop with the demo library
open -n dist/Ahenk.app --args --demo-scene album --demo-backdrop --language tr
swift Scripts/widget-shot.swift /tmp/album.png            # only Ahenk's windows, cropped to the widgets
pkill -x Ahenk
```

Scenes (`--demo-scene`): `albums` (default), `search` ("nova"), `album`, `artist`, `queue` (an album started, two songs
added, the queue open), `small`, `small-search`, `status` (a message), `loading` (a song held while starting), `off` (player
hidden). Scenes, `--language en|tr` and smoke runs work on an in-memory copy of the settings: nothing they change is saved.
`--demo-backdrop` covers the screen with Ahenk's own generated wallpaper (under the widgets) so the glass can be captured
without the user's desktop.

New smoke check `desktopPlayer`: the widget window sits one level above the desktop icons, joins every Space, stays put,
is a non-activating panel and never main; the playing demo artist's albums and a search arrive through the demo catalog; an
album song picked from the player plays through Ahenk's queue until the demo source confirms it, with the rest of the album
up next; seven player states, the clock, the list and the queue panel are drawn offscreen in English and Turkish (glass is
painted in these bitmaps; Core Animation also flattens the cover flow's 3D turn there). `resources` checks every SF Symbol
the widgets use. Nothing appears on screen.

Measured on the M5 (release build, demo playing, Soft Glow light, one 1512 × 982 display, load ~2.5): player + light
**3.94 %** CPU vs light alone (player off) 3.73 %, so **the player costs ~0.2 %** while a song plays; paused (light faded
out, widgets on screen) **0.05 %**. Footprint 97 MB with both running.

### Decisions

- **One window per widget, one level above the desktop icons.** `DesktopWidgetWindow` is a borderless non-activating
  `NSPanel` at `CGWindowLevelForKey(.desktopIconWindow) + 1` (`isFloatingPanel = false` is set *before* the level: it
  resets the level), `.canJoinAllSpaces`, `.stationary`, `.ignoresCycle`; below every app window, above the icons, on every
  Space, left alone by Mission Control and Show Desktop. Clicks reach a window only where it has paint, so clear margins pass
  clicks to the desktop; areas that must take drags (the clock, the cover flow) get an invisible 1/255 fill (`hitArea()`).
  `ignoresMouseEvents` is never set (setting it at all turns that off).
- **Focus.** Clicks never activate Ahenk. The hosting view says `needsPanelToBecomeKey = false`, so buttons, menus and lists
  leave the user's app as it is; only the search field (an AppKit text field inside) makes the player's panel key, when
  clicked or when the search button / "Add Songs" asks (`makeKey`, still without activating Ahenk). Esc, Return and a pick
  give the keyboard back. SwiftUI focuses the first text field of a new window; the controller clears that.
- **Places.** Each widget's anchor (clock and list: top left; player: bottom centre) is saved relative to the display's
  visible frame when a drag ends (`settings.layout`, per display UUID) and kept on screen with an 8 pt margin. The player
  window grows upwards at once when a page or the search opens and shrinks after its content has faded out (0.32 s), always
  around the saved anchor, so the bar never moves. The widgets live on Settings › Desktop Player › Display (main by default).
- **The queue.** The music apps' scripting cannot read or change their own queues, so Ahenk keeps one (`PlayQueue`) and starts
  each song itself 0.35 s before the previous one ends (`QueueConductorPolicy`); it follows the source when it moves to the
  queue's next song by itself, takes back when autoplay picks something in the last 4 s, and steps back when the user plays
  something else there. When the queue moves on by itself (`interactive: false`), nothing is brought to the front: a song that
  would need the user's click is skipped (up to eight in a row). The queue panel opens beside the player when it fits there
  without covering another widget, else as a page above the search field (on a 1512 pt screen with the default layout).
- **Apple Music.** A library song plays by AppleScript (`play` the track with its persistent ID — from Continue Playing or a
  Music playlist, inside that playlist so Music goes on through it — else a library search by title and artist, preferring
  the same album). macOS gives other apps no way to start an Apple Music *catalog* item without MusicKit (an App ID with the
  MusicKit service and a provisioning profile, excluded by the no-accounts rule), so a song that is not in the library opens on
  its catalog page in Music (`music://music.apple.com/…?i=<id>`; for a song that played elsewhere, the iTunes catalog's match
  gives the page) and the status says "press Play there"; the queue then waits up to 90 s for it. That is the most reliable
  way available; it brings Music to the front (the user asked to play the song).
- **Spotify.** `play track "spotify:track:<id>"` by AppleScript. The ID comes from the song itself (Continue Playing) or from
  ListenBrainz Labs' public "Spotify ID from metadata" mapping (MetaBrainz; no key; batched, one request a second, hits kept a
  month, misses three days). Without a match, Spotify's own search opens (`spotify:search:…`).
- **Odesli (song.link) was evaluated and is not used:** `api.song.link/v1-alpha.1/links` answers
  `401 PUBLIC_API_ACCESS_DEPRECATED` to every request without a key (checked again on 2026-11-09), so it cannot map catalog
  items without an account. Spotify IDs come from ListenBrainz (above); the music sites will find a pick by its title, artist
  and album themselves through Step 7's extension (`BrowserPlayRequest` carries the song and, for the Spotify Web Player, the ID).
- **Browser sources** are pickable now; playing there goes through `NowPlayingServices.browserPlayback`
  (`BrowserPlaybackRouting`), which is `nil` until Step 7, so the player says "Playing in the browser needs the Ahenk browser
  extension." Playlists and the volume of sites go through the same protocol.
- **Asking for Automation.** Reading (playlists, volume) never asks and never launches an app. Playing a pick in Music or
  Spotify is something the user asked for: the app is launched in the background if needed and macOS may ask for Automation
  once (Step 2's rule "never prompts by itself" still holds for everything else).
- **Where picks play.** The source picker sets `player.listeningSource`; Automatic follows the source that plays, and a
  Continue Playing song goes back to where it played. With "pause the previous source when switching" on, picking another
  source pauses the others.
- **Search covers every source with Apple's catalog** (the iTunes Search API; artists and songs in one request, albums from
  the songs), shown with the picked source's own wording ("Search Spotify"); the pick then plays in that source.
- **Performance.** SwiftUI never redraws per frame: the progress line is an AppKit layer moved by a timer about one pixel per
  step (at most four steps a second, `ProgressSchedule`), only while playing and visible; the playing bars are a Core
  Animation loop capped at 20 fps, only while playing and visible; the clock redraws once a minute and only while its window
  can be seen; the cover flow animates only while it moves. Catalog lookups happen only while the widgets are on screen.
  Closed widget windows are released at once (AppKit frees closed windows on its next event, which an idle background app may
  not get for a long time, so a no-op event is posted).
- **Glass.** `glassEffect(.regular.tint(...))` on macOS 26 with a faint shade under the content (small glass turns almost
  clear on bright wallpapers); `NSVisualEffectView` (.hudWindow, behind window) with the tint on 14.2–15. Tint: the playing
  cover's `palette.backdrop`; highlights: `palette.vivid[0]`; the clock: `palette.onDark[0]` mixed with white.
- **Language.** Every widget window gets the app's language as its SwiftUI locale (upper-case titles are "NOW PLAYING" in
  English, "ŞU AN ÇALIYOR" in Turkish, whatever the Mac's language). The search prompt is a whole sentence per source so
  Turkish gets the right ending ("Spotify'da ara", "Apple Music'te ara").

### Deviations from PLAN.md

- Odesli is not used (see Decisions); its decoding has no tests. ListenBrainz's mapping is tested instead.
- Apple Music catalog songs that are not in the library open in Music for one click instead of starting by themselves.
- The queue panel opens as a page above the search field when it cannot sit beside the player without covering a widget.
- The lyrics toggle flips the setting; the lyrics widget itself is Step 6 (`DesktopWidget.lyrics` is reserved).
- Extra launch arguments `--demo-scene`, `--demo-backdrop`, `--language`; extra script `Scripts/widget-shot.swift`; extra
  folders `AhenkKit/Player`, `AhenkApp/Desktop/Views`.
- **Shared API changes** (call sites and tests updated): `HTTPFetching.post(_:json:)` (default throws); `DemoProvider` gains
  `library`, `play(_:startDelay:)`, `volume`/`setVolume`; `NowPlayingServices` gains `catalog`, `spotifyFinder`, `scripts`,
  `presence`, `fetcher`, `browserPlayback`, `storefront`, `pausePlayers(otherThan:)`, and the demo's Continue Playing starts
  with invented history; `OfflineFetcher` moved there from `SmokeRunner`; `PlayerSettings` gains `clockScale`,
  `showPlayerBar`, `listeningSource`; `AppEnvironment` gains `desktopPlayer` and uses in-memory settings for scenes and
  `--language`; `LaunchOptions` gains `demoScene`, `demoBackdrop`, `language`, `usesDetachedSettings`.

### For Step 6 (lyrics)

- **Where the lyrics view lives:** a fourth widget window. `DesktopWidget.lyrics` exists (anchor `.center`, default place
  right of the middle in `WidgetPlacement.defaultFrames`); in `DesktopPlayerController` return your view from
  `root(for: .lyrics)`, its size from `size(of: .lyrics)`, and make `shouldShow(.lyrics)` follow `settings.lyrics.enabled`
  (it returns `false` now). Dragging and saved places then work as for the others. "Beside the album cover": the player's
  frame is `visibleWindows[.player]`; the cover flow's centre card is 170 pt wide in the player's upper part.
- **Lyrics toggle:** the bar's quote-bubble button calls `DesktopPlayerModel.toggleLyrics()`, which flips
  `settings.lyrics.enabled` (also the menu bar's Lyrics item); `lyricsOn` reads it. Observe the setting in the controller (it
  already re-applies on `settings.player` changes; add `settings.lyrics`).
- **Palette and fonts:** `DesktopPlayerModel.theme` (`PlayerTheme`: `accent` = `palette.vivid[0]`, `glass` =
  `palette.backdrop`, `clock` = `palette.onDark[0]` + white, `palette`), `widgetGlass(_:tint:)`, `desktopTextShadow()`,
  SF Pro everywhere; the clock is SF Pro Ultralight Compressed. The song and its position come from `NowPlayingModel`
  (`snapshot`, `lyrics`, `lyricLine(at:)`); do not drive SwiftUI per frame (see Step 1/3 notes) — use a leaf layer view and a
  display link only while visible (`ProgressLineView` is a small example of pausing on occlusion).
- **Checks:** `--demo-scene albums --demo-backdrop` then `swift Scripts/widget-shot.swift out.png` shows the widgets on
  their glass; add a lyrics state to the smoke check's offscreen renders (`renderWidget`).

### Known gaps and risks

- **Nothing was played in Music or Spotify** (the rules forbid touching the user's playback): the scripts are tested against
  fixtures, the routing and the queue against the demo. First real use: pick a library song with Music as the source, then a
  catalog-only song, then a Spotify song; watch the `[player]` lines in the log.
- Spotify IDs from ListenBrainz can miss newer releases or pick another edition of a song.
- Apple Music: a catalog page needs the user's click; library search by name can pick a different version.
- Click-through of clear areas follows macOS's handling of transparent window pixels; it could not be clicked through live
  here (no input on the user's screen).
- Keyboard focus of the search field (a non-activating panel taking the key) and every hover/drag/scroll interaction were
  checked in code and through scenes, not by clicking.
- The queue panel's side placement was only seen as a page on this 1512 pt screen.
- Once the search field exists, macOS's text input services keep two hidden windows in Ahenk (`TUINSWindow`,
  `SPRoundedWindow`); they are never on screen.
- Covers in the cover flow come from Apple's catalog at the shown size; a different edition's artwork is possible.

## Step 6 — Lyrics (done, 2026-11-09)

### What exists

```
Sources/AhenkKit/Lyrics/
  LyricsProvider      LyricsQuery (+ Spotify recording ID, cache key, cleaned variant, match text), LyricsResult,
                      LyricsTimingAuthority, LyricsResponse, LyricsVersion; LyricsProvider (+ versions, search, lyrics(of:))
  LRCParser           LRC and enhanced LRC; blank or symbol-only timed lines stay as pause markers
  LRCLIBProvider, MusixmatchProvider, NetEaseProvider   ported from DynamicIsland; versions and search added
  LyricsChain         providers asked together: synced wins, a cleaned title only after the original missed,
                      Spotify waits for the provider that proves the recording; versions/search merged; "all failed"
  LyricsConsensus     timeline vote between three or more uploads (ported)
  LyricsCache         ~/Library/Caches/Ahenk/Lyrics, one JSON per song, 600 files, memory LRU (ported)
  LyricsSongStore     ~/Library/Application Support/Ahenk/LyricsSongs.json: per song the user's nudge, the measured
                      offset (bound to the lyrics' timing fingerprint) and the picked version; 2000 songs
  LyricsFinder        the pick, then the cache, then the providers; misses remembered 30 min
  LyricsTimeline      sung ends, instrumental parts (intro, interlude, outro), LyricsScene: what is on screen at a time
  LyricsStyleMath     wrapping, fisheye lens, karaoke fill, typewriter, spread, neon, echo, glitch, cinema, countdown,
                      LyricsColors (light ink from the cover), LyricsLayout (widget size)
  AutoSync/           OnsetNovelty + LyricOffsetEstimator (ported) with a tracked-beat alias guard; LyricsSyncCapture
                      (a window of analysed audio at 16 kHz), LyricsSyncPlan, LyricsSyncSession (two windows must agree)
Sources/AhenkApp/Lyrics/
  LyricsController    the playing song's lyrics: phase, source, offsets, versions, search, pick, nudge
  LyricsWidget        the desktop widget (SwiftUI shell): the stage, the hover bar, Other Lyrics and Search Lyrics panels
  LyricsStageView     AppKit/Core Animation: cover, scrim, the style, the countdown, the states, the display link
  LyricStyleRenderer  render context, line visuals (one sprite layer per word or letter), the scrolling stack
  LyricStyles         the eight styles
  LyricsTypesetter    CoreText into balanced rows; LyricSpriteCache (each unit drawn once, glow and shadow baked in)
  LyricsFonts         each style's macOS font; LyricsPreview: Settings gallery + one shared 30 fps clock
  LyricsAutoSync      listens for windows, applies the measured offset; LyricsCheck: the smoke check's renders
Tests/AhenkKitTests/  385 tests in 61 suites (was 315/51): LRC parsing, timeline (lookup, sung ends, pauses, countdown,
                      glides), provider decoding with invented fixtures, chain policy, finder, consensus, stores, style
                      math, colours, layout, placement, launch options, auto-sync
```

The lyrics sit in their own desktop widget window, above the player by default, the album cover on the left and the lines
beside it, in the cover's colours with a soft shadow and a faint dark scrim (readable on any wallpaper). A line glides in a
little before it is sung, the previous one leaves above, the next waits below (styles differ). Before the first line the
song's title and artist show with a countdown; an instrumental part of at least 6 s shows a music note in a ring that empties
until the next line, the seconds left under it; after the last line the note stays. Loading shows the title with pulsing
dots; "no lyrics", "instrumental" and "could not be loaded" show the title with a caption; words without timing scroll with
the song ("Not synced"). Under the pointer a bar offers: earlier/later (0.2 s steps, kept per song), Other Lyrics, Search
Lyrics, the cover on/off and a menu (style, reset timing, back to Ahenk's pick, Lyrics Settings…, Hide Lyrics). Other Lyrics
lists every provider's versions (synced first, line count, length, album; the one shown is ticked); Search Lyrics searches
by song and artist; a pick is kept for the song. The player bar's lyrics button and the menu bar's Lyrics item switch them.

| Style | Font (macOS) | Motion |
|---|---|---|
| Fisheye | Superclarendon Black | a lens travels along the line as it is sung: words under it grow, the rest shrink and make room, all bob with the beat |
| Spread | SF Pro Expanded Heavy | letters fly in from twice as far, settle, drift apart while sung, fly out |
| Karaoke | SF Pro Rounded Heavy | the line lights up from its first letter to its last (a glowing edge leads), glows with the beat when sung; the next line waits |
| Typewriter | American Typewriter Semibold | letters strike one by one, a caret blinks, the page feeds up with the two lines before |
| Neon | SignPainter HouseScript Semibold | each word's tube flickers on in turn and hums, the halo swells with the beat, every line in the next cover colour |
| Echo | Futura Condensed ExtraBold | three copies in the cover's colours trail every move, each beat sends a ripple |
| Glitch | SF Mono Heavy | the line decodes out of random characters, a colour split widens with onsets, strong beats tear it |
| Cinema | Didot Bold | a film title: slow dissolve on a soft dark ellipse, a settling zoom, a hairline that grows as it is sung |

### Build, run, verify

```sh
swift build && swift test             # 385 tests, no warnings
./Scripts/make-app.sh && ./Scripts/smoke.sh --snapshots    # lyrics-*.png, desktop-lyrics-*.png, settings-lyrics-*.png
open -n dist/Ahenk.app --args --demo-scene albums --demo-backdrop --draw-covered --lyrics-style neon --language tr
open -n dist/Ahenk.app --args --demo-scene lyrics-versions --demo-backdrop --draw-covered   # or lyrics-search
open -n dist/Ahenk.app --args --demo --settings lyrics     # the live style gallery
swift Scripts/widget-shot.swift /tmp/lyrics.png
pkill -x Ahenk
```

New launch arguments: `--lyrics-style <style|off>`, `--demo-position <s>` (the demo song starts there), `--draw-covered` (demo:
the lyrics keep moving while app windows cover them, for captures and measurements), `--smoke-only <a,b>`; scenes
`lyrics-versions`, `lyrics-search`.

Smoke check `lyrics` (all `ok`): every style drawn offscreen at four moments of a demo song (the intro, a line gliding in,
the line being sung, an instrumental part; the English song in the English pass, the Turkish one in the Turkish pass), each
scene, line and countdown checked against the timeline; loading/none/instrumental/failed/plain states; the widget with its
bar and both panels in both languages; the controller finds, lists three versions, picks the late one (its timing shows),
returns to the automatic pick, nudges and searches; one 32 s auto-sync window of the demo beat is measured (92 ms) and
changes nothing; every style font has the Turkish letters and no two share a typeface. `resources` checks the new symbols.

Endpoints (2026-11-09, invented queries only, no lyric text looked at): LRCLIB search 200 with no results and get 404,
Musixmatch token 200 with a token, NetEase search 200 with no songs, the shapes the decoders expect.

Measured on the M5 (release build, demo, Soft Glow, one 1512 × 982 display, `--draw-covered` because app windows cover the
desktop here): light + player without lyrics 4.4 % CPU, 99 MB; with lyrics Fisheye 5.8 % (**+1.4 %**, every word moves each
frame), Karaoke 5.4 %, Neon 5.3 %, Glitch 5.1 %, Echo 5.1 %, Cinema 4.9 %, Spread 4.8 %, Typewriter 4.8 % (**+0.4–1.0 %**);
footprint 104–143 MB (Echo keeps the most sprites); paused **0.07 %**. Settings › Lyrics' gallery draws 8 tiles at 30 fps
only while visible.

### Decisions

- **Sprites, then only transforms.** A line is laid out with CoreText into balanced rows; each word (or letter) is drawn once
  into an image with its glow and shadow baked in; frames only move, scale and fade those layers, in one transaction, with
  unchanged values skipped. No masks, filters or live shadows on moving layers (offscreen passes; `render(in:)` would drop
  them in the smoke renders): Karaoke's wipe crops with `contentsRect`.
- **Drawing only while it shows.** The stage's display link (`NSView.displayLink`) runs while its window is visible (occlusion),
  the song plays and there are lines: 60 fps while lines glide, 30 or 20 fps in between, 30 at most on battery, in Low Power,
  Optimized Mode or when hot; a pause draws one last frame and stops. SwiftUI updates the widget only on song, clock and
  settings changes. On this Mac the widgets sit under app windows, so the lyrics stop until the desktop shows (as the clock
  does); `--draw-covered` is for captures.
- **Timing.** Lyric time = the song's interpolated position + Settings' offset + the song's offset (the user's nudge replaces
  the measured one); positive shows lines earlier. Lines glide in 0.18 s early (Cinema 0.35 s) so they are in place when sung.
  Sung ends come from word timing or are estimated (lines close together are sung almost to the next; a line before a pause
  lasts as long as its words); a pause of 6 s or more, or after a timed blank line, is instrumental; an intro of 3 s or more
  shows the title. No output-latency compensation: with Bluetooth, lines may come a little early (the offset covers it).
- **Lookups.** Only while lyrics are on, only for music (or unlabelled players), never videos, podcasts or adverts. LRCLIB
  first, then Musixmatch and NetEase, asked together (DynamicIsland's chain and policy); each can be turned off. The cache key
  is the Spotify recording ID or title/artist/album/length. A pick is stored in the song store (without lyrics) and its lyrics
  in the cache under a pick key; choosing another version forgets the song's nudge.
- **Placement.** Settings › Lyrics › Position: Above the Player (default; right of the list when they would overlap), Middle
  or Top of the Screen. A drag overrides it (saved per display); picking a position forgets the drag. Lyrics show even when
  the rest of the player is off. Only painted parts take clicks (cover, text, scrim); they also drag the widget.
- **Fonts.** macOS fonts only (nothing bundled), each with the Turkish letters; no all-capital faces (small capitals draw the
  Turkish "i" without its dot) and no style upper-cases lyrics (the lyrics' language is unknown).
- **Auto-sync, evaluated.** DynamicIsland's measurement core is ported: the vocal-band onset novelty (HPSS) and the offset
  estimator with its strict two-window consensus. Its large controller (affine and piecewise timing profiles, retry ledgers
  across runs, capture provenance machinery) is not: Ahenk keeps a constant offset per song and lyrics fingerprint, at most four
  windows per song and run, and takes the audio from Step 3's analysis pump (no second tap; only on a tap of the followed
  player, never on the fallback that hears every app; never for lyrics a provider proved for the recording; never over a
  nudge). Testing it on the demo beat showed a real danger: the estimator locked onto the backbeat (lead −1.536 s, three beats
  at 120 BPM) in both windows and they "agreed", which would have moved correct lyrics. Its own alias guard missed it because
  novelty autocorrelation found the two-beat backbeat (0.992 s). Ahenk adds the beat Step 3's tracker locked to: a lead on a
  whole number of beats is refused. With that, the bare beat never moves anything (tested).

### Deviations from PLAN.md

- Auto-sync is a constant per-song offset with two-window consensus (see Decisions); no drift models.
- The lyrics widget has its own cover (the option hides it); "position" in Settings is a placement preset.
- Words without timing scroll with the song's progress until Step 10 aligns them.
- Extra launch arguments `--lyrics-style`, `--demo-position`, `--draw-covered`, `--smoke-only`; scenes `lyrics-versions`,
  `lyrics-search`.
- **Shared API changes** (call sites and tests updated): `NowPlayingModel` lost `lyrics`, `lyricLine(at:)` and `attach(lyrics:)`
  (`LyricsController` owns lyrics; the General pane's demo card reads it); `NowPlayingServices.lyrics` became `lyricsFinder` +
  `makeLyricsChain`; `HTTPFetching.send(_:)` (default: `get`); `LyricsProvider` gained `reliability`,
  `supportsCanonicalSpotifyLookup`, `fetchResponse`, `versions(for:)`, `search(_:)`, `lyrics(of:)` with defaults; `LyricsQuery`
  gained `spotifyTrackID`, `cacheKey`, `sanitized`; `SyncedLyrics.timingFingerprint`, `shifted(by:)`; `LyricsSettings.position`;
  `WidgetPlacement.defaultFrames(…, lyrics:)`, `lyricsFrame`; `DesktopPlayerController.init(…, lyrics:, power:, …)`;
  `AudioAnalysisPipeline.lyricsCapture`; `AudioTapEngine.listen(forLyrics:)`, `hearsFollowedPlayer`; `DemoProvider` versions and
  search; `DemoCatalog.previewLyrics`; `LaunchOptions` new fields; `AppEnvironment.lyrics`, `lyricsSync`.

### For Step 7 (browser bridge)

- **When lyrics load:** `LyricsController` looks up lyrics for `.music` and `.unknown` content only. Report music sites as
  `.music`; plain YouTube videos (`.video`) get none.
- **Sites' own lyrics:** Amazon Music, Spotify Web, YouTube Music, Deezer and TIDAL show synced lyrics for the exact recording
  they play. Let the extension send them for the tab's song (lines with start times, words when the site has them) and add a
  `BrowserLyricsProvider: LyricsProvider` (AhenkKit/Bridge) that answers for that song with `.synced` and
  `timingAuthority = .canonicalRecording` (their timing belongs to the recording, which also keeps auto-sync away), and
  `.notFound` at once otherwise. Put it first: in `NowPlayingServices.live`, `makeChain` becomes
  `LyricsChain(providers: [siteLyrics] + LyricsChain.standard(http:disabled:).providers)`. Give it a name for the source line
  (`LyricsController.displayName(ofProvider:)`). Never log site lyrics (the controller logs counts only).
- **Spotify Web:** report `Track.id` as `spotify:track:<id>` so `LyricsQuery` carries the recording ID (Musixmatch proves it).
- **Position:** lines follow the snapshot's `elapsedTime`, `timestamp` and `playbackRate`; report them precisely (a stale
  timestamp shows as late lyrics).

### Known gaps and risks

- No real lyrics were looked at here: providers are tested with invented fixtures and the endpoints with invented queries.
  Musixmatch's desktop API is unofficial and may change or refuse; NetEase can be slow or unreachable from some places.
- Auto-sync has not heard real music (no system audio permission on this Mac). The ported novelty (HPSS) does not pick up
  synthetic sung tones (its 0.72 s median smears held notes and drops short ones), so its hit rate on real vocals is unknown;
  it is built to do nothing when in doubt.
- The hover bar appears only while the pointer is over painted parts of the widget (text, scrim, cover).
- Lines longer than three rows shrink to fit; right-to-left scripts were not tried (CoreText shapes them, rows run left to right).
- `CALayer.render(in:)` in the smoke check draws the layer tree without some window-server effects; the live captures were
  checked by eye in both languages.

## Step 7 — Browser bridge and extension (done, 2026-11-09)

### What exists

```
Sources/AhenkKit/Bridge/
  BridgeProtocol        the wire protocol (version 1): hello/welcome, tabs, tab, tabRemoved, lyrics, result, command,
                        request, ping/pong, error; every field decoded on its own; BridgeProtocol (ports, timing, negotiate)
  BridgeOriginPolicy    who may connect: the extension's origins on the loopback host, nothing else
  BridgeRegistry        the bridge as a pure state machine (connections, hello, identity, tabs, timeouts → effects)
  BrowserBridgeServer   NWListener + NWProtocolWebSocket on 127.0.0.1, first free port of 42617–42620; BrowserBridge
  BridgeLoopbackClient  a stand-in extension (URLSessionWebSocketTask) for tests and the smoke check
  BrowserSite           site ↔ MusicSource, host names, song IDs (spotify:track:…, watch URLs, song pages)
  BrowserIdentity       bundle IDs a reported browser name may stand for (fallback when the socket owner is unknown)
  BrowserPlaybackPolicy which tab takes a request, where a new tab opens, answers, songs/playlists as the player lists them
  BridgePlaybackRouter  BrowserPlaybackRouting over the server: play a pick, playlists, a site's queue, volume
  BrowserLyricsProvider the sites' own synced lyrics (memory only), first in the lyrics chain
  BrowserBridge         BrowserTabReport (+ tab fields), BrowserProvider (one player per tab, shadows the system guess),
                        BrowserPlaybackRouting (+ playPlaylist, queue, hasVolume, isConnected), BrowserQueue
  NowPlaying/Hub        HubCore.setShadowing + shadowGrace, HubInput.shadowsSameApp
Sources/AhenkApp/Bridge/
  BrowserProcessLookup  which app holds a connection: the kernel's socket table, then the app bundle of that process
  BrowserExtensionInstaller   "Install Browser Extension…": the folders in Finder and the steps per browser
  BridgeCheck           smoke checks `bridge` and `bridgeLive`
Extension/              the browser extension, plain JS, no build step
  manifest.json         Chrome MV3 (Chrome 116+; Edge, Brave, Arc, Opera, Vivaldi; Search), `key` → fixed ID
  firefox/manifest.json the same scripts for Firefox 128+ (`browser_specific_settings.gecko`)
  background.js         the WebSocket to Ahenk, tabs, commands, requests (jobs that survive a page load)
  content/relay.js      isolated world: page ↔ background, reconnects when the worker restarts
  page/hooks.js         MAIN world at document_start: Media Session handlers/metadata/position, media elements, lyrics JSON
  page/sites.js         per-site readers and actions (selectors on data-testid/aria/state attributes, never labels)
  page/engine.js        reads the tab, reports changes, runs commands and requests
  lib/common.js, lib/protocol.js, lib/lyrics.js   pure helpers (node --test)
  popup/, _locales/{en,tr}, icons/ (Scripts/make-extension-icons.swift)
Tests/Extension/        node --test for the pure helpers (23 tests); e2e.mjs + mock/ (a stand-in music site)
Tests/Fixtures/bridge/  wire fixtures both sides test against (Swift decodes them, JS must produce them exactly)
Tests/AhenkKitTests/    434 tests in 72 suites (was 385/61): protocol, origins, registry, server (real sockets),
                        tabs as players, sites, identity, hub dedupe/conflict/tap, playback policy, site lyrics
```

Data flow: page (MAIN world) → `window.postMessage` → relay (isolated) → `runtime.Port` → background → WebSocket →
`BrowserBridgeServer` → `BridgeRegistry` → `BrowserTabReport`s → `BrowserProvider` → `NowPlayingHub` (one player per tab,
`PlayerID(source: site, bundleIdentifier: browser, instance: "<profile>/<tabId>")`). Commands go back the same way and are
answered with a `result`; the desktop player's picks, playlists, queue and volume go through `BridgePlaybackRouter`
(`request` → a job in the tab → `result`). Lyrics a site loads for itself → `lyrics` → `BrowserLyricsProvider`.

| Site | Reads | Commands | Search & play | Playlists | Queue | Own lyrics | Volume |
|---|---|---|---|---|---|---|---|
| YouTube Music | Media Session, player bar, player API (exact position), watch URL | transport, seek, like, shuffle (when the bar shows a state), repeat off/all/one | ✓ | sidebar: list, songs, play from any | read, play, remove | ✓ (Lyrics tab) | ✓ |
| YouTube | player API (title, channel as artist), music vs video | transport (next/previous in a playlist), seek, like, shuffle in a playlist | ✓ | sidebar: list, songs, play | playlist panel: read, play | — | ✓ |
| Spotify Web Player | Media Session, now-playing widget, `spotify:track:<id>` | transport, seek, like, shuffle, repeat off/all/one | ✓ (by track ID when known) | sidebar: list, songs, play | — | ✓ (lyrics view) | read |
| SoundCloud | Media Session, play controls, track page | transport, seek, like, shuffle, repeat | ✓ | — | read, play | — | read |
| Amazon Music | Media Session, transport bar | transport, seek, shuffle, repeat | ✓ | — | — | ✓ (lyrics view, shape found by scanning) | — |
| Deezer | Media Session, player bar, track ID | transport, seek, like, shuffle, repeat | ✓ | — | — | ✓ | — |
| TIDAL | Media Session, footer player, track ID | transport, seek, like, shuffle, repeat | ✓ | — | — | ✓ | — |

Transport = play, pause, next, previous. Only what a tab can do right now is offered (`can` in each report). Any other
site that publishes Media Session still shows through the system's Now Playing as before.

### Build, run, verify

```sh
swift build && swift test             # 434 tests, no warnings
node --test "Tests/Extension/*.test.mjs"   # 23 tests (also part of ./Scripts/test.sh)
./Scripts/make-app.sh && ./Scripts/smoke.sh --snapshots   # bridge check; settings-sources-full-*.png, extension-installer-*.png
./Scripts/bridge-e2e.sh               # end to end: headless test Chromium + the extension + a mock site, driven by Ahenk
open -n dist/Ahenk.app --args --demo --settings sources   # the extension section with an invented connected browser
```

Smoke check `bridge` (every run): a real server on a spare loopback port; a web page's origin is refused (HTTP 400); the
extension's origin is welcomed; a reported tab becomes the hub's player and hides the system's guess of the same song in the
same browser; a pause goes to the tab and back; the site's lyrics answer as the recording's own; a pick reaches the tab; a
connection that never says hello is closed; the kernel's socket table names the connecting process; the tab leaves with its
connection; the packaged app carries `Extension/Chromium` (its key gives the accepted ID) and `Extension/Firefox`.

`bridgeLive` (`--smoke --smoke-only bridgeLive --bridge-port <p> --bridge-wait <s>`, run by `Scripts/bridge-e2e.sh`):
Playwright 1.63.0's own Chromium (Chrome for Testing 1243, new headless mode, muted, a throwaway profile) loads a copy of the
extension whose default port is the test port (it can never reach an Ahenk the user runs) and opens music.youtube.com;
every request is answered from `Tests/Extension/mock` (a stand-in with the site's element names, a player API object, Media
Session, a generated tone and invented songs) and every other host is refused, so nothing reaches the real site. Ahenk then
drives the tab: pause, play, seek to 1:00, like, unlike, shuffle, repeat one, repeat off, next, previous, the site's lyrics
(4 lines), volume read and set, queue read / play item 3 / remove item 4, playlists (2; one has 3 songs; played from its
second), search and play (a page load; the near miss is passed over). Passed in ~4 s; the browser identified as
`com.google.chrome.for.testing` with its main process. `AHENK_E2E_SHOTS=<dir>` also pictures the popup.

Measured on the M5 (release build, live, nothing playing, no browser connected): **0.0 % CPU** over 12 s with the server
listening on 127.0.0.1:42617 (the listener waits in the kernel; the only timer runs while connections exist), ~104 MB.

### Decisions

- **Wire protocol.** One JSON object per text frame, `type` first. The extension says `hello` (protocol, minProtocol,
  extension version, browser, a random per-profile ID); Ahenk answers `welcome` with the version both speak or `error` and
  closes. Unknown types and fields are ignored and a wrong value drops only that field, so either side can grow. The
  extension pings every 20 s (also what keeps an MV3 service worker alive, Chrome 116+); Ahenk closes a connection silent for
  65 s, one without hello after 5 s, frames over 1 MB and connections beyond 32. Ports 42617–42620: Ahenk takes the first
  free one, the extension tries them in order and accepts only a `welcome` from "Ahenk" (Settings › Sources › First Port and
  the popup's Connection change both).
- **Who may connect.** Browsers set `Origin` themselves: Chromium origins only with our ID (fixed by the manifest's `key`,
  `goajefoldohohgnmcfkpkembdpjbpfde`); Firefox (`moz-extension://<uuid>`) and WebKit (`webkit-extension://<uuid>`) give each
  installation a random origin, accepted when well formed; the Search browser runs Chrome extensions on WebKit, ignores the
  key and names an unpacked one `chrome-extension://local-<8 hex>` (read from its source), accepted too. `Host` must be the
  loopback address (no DNS rebinding). Web pages get HTTP 400.
- **Which browser.** The other end of the loopback socket is found in the kernel's file tables (`proc_pidinfo`, this user's
  processes, no permission); its app is the outermost `.app` its executable lies in (Chromium's network helper lives inside
  the browser's bundle) and the main process the topmost ancestor in that bundle. LaunchServices' "responsible process" is
  only a fallback: a browser started from a terminal is "the terminal's" (the first e2e run reported the terminal app).
  Last resort: the reported name → a running app. Tabs wait for this (≤ 1.5 s) so each joins the hub once, under its browser;
  a reconnect from the same profile keeps its tabs (no flicker) and is looked up again.
- **One song, one player.** The bridge's reports shadow lower-priority reports of the same app (the system reader's guess)
  that describe one of its songs (core titles overlap, artists agree) or have no title; a guess that matches no tab is
  another player in that browser (a site the extension does not know) and shows after 4 s (`shadowGrace`), so a song change
  seen first by the system never flashes a second player. Two tabs playing raise the existing conflict question; choosing one
  pauses the others through the bridge.
- **Song IDs.** `spotify:track:<id>` for the Spotify Web Player (the lyrics' recording ID), the watch URL for YouTube and
  YouTube Music, the song's own page (no query) or `<site>:<id>` elsewhere. Content kind comes from the page: YouTube's
  category, a "- Topic"/VEVO channel or a tag in the title make music, else video; adverts and podcasts are marked. Music
  sites move the light, plain videos do not (`AudioCapturePolicy.reactsTo`), and the tap targets the tab's browser.
- **In the page.** MAIN-world scripts at `document_start` (hooks before the site's own code): Media Session handlers,
  metadata and position, played media elements, and the JSON responses that may hold lyrics (a copy made before the site
  reads the body). The engine polls 1 s while playing (2 s paused, 5 s hidden) and reports only noticeable changes (a seek,
  state, song, capabilities…) or every 30 s while playing. Commands use the site's own Media Session handlers first, then its
  player API, then its buttons, then the media element. Requests that need another page navigate there and continue in the
  next page (a job's "phase"); a job also survives a page load it did not announce, and ends when its tab closes.
- **Sites' own lyrics** are read only from responses the page fetched for its own lyrics view (no request of ours), matched
  to the tab's song (the track ID when the response names one, the length otherwise), kept in memory (24 songs), never
  cached, never logged. They come first in the chain (`answersFromMemory`, before the disk cache) as
  `.canonicalRecording` (no auto-sync), replace what shows when they arrive mid-song, and picking them in Other Lyrics is the
  automatic pick (nothing stored).
- **Where requests go.** The site's playing tab, else its selected or most recently used tab; with no tab of the site the
  browser used last opens one (play and play-playlist only), and a blocked autoplay answers "press Play there". The site's
  queue shows in the queue panel while Ahenk's own queue does not play; site playlists play in the site in its own order.
- **Demo.** Settings › Sources shows an invented connected browser (no server runs), so the section can be seen and
  snapshotted; `--smoke --snapshots` also writes the whole Sources pane (`settings-sources-full-*`) and the install steps.

### Deviations from PLAN.md

- The Search browser is WebKit, not Chromium: it loads the same `Chromium` folder through its own extension engine; its
  unpacked origin form is accepted (see Decisions). Firefox and WebKit origins are per installation, so any extension there
  could connect (web pages still cannot).
- Firefox loads the extension as a temporary add-on (removed when Firefox quits); a permanent install needs Mozilla's signing.
- Queue editing (remove) only on YouTube Music; reading a site playlist's songs opens that playlist's page in the tab (sites
  list a playlist's songs only there; playback goes on).
- Extra: launch arguments `--bridge-port`, `--bridge-wait`; `Scripts/bridge-e2e.sh`, `Scripts/make-extension-icons.swift`;
  `Tests/Extension` (node tests, e2e, mock, `package.json` pinning Playwright 1.63.0; `node_modules/` is ignored);
  Settings › Sources › First Port.
- **Shared API changes** (call sites and tests updated): `BrowserTabReport` gained `trackIdentifier`, `processIdentifier`,
  `isPositionKnown`, `playbackRate`, `browserTabID`, `connectionID`, `bridgeCapabilities`, `volume`, `isActiveTab`,
  `lastActive`, `browserName`, `playerID`; `BrowserPlaybackRouting` gained `playPlaylist`, `queue`, `playQueueItem`,
  `removeQueueItem`, `hasVolume`, `isConnected`; `BrowserPlayOutcome` gained `.noExtension`, `.opened`; `HubInput.shadowsSameApp`,
  `HubCore.setShadowing`; `LyricsProvider.answersFromMemory`, `LyricsFinder.Origin.playingSource` (and `choose` of a
  memory provider's version clears the choice); `MusicSource.isSite`; `NowPlayingServices` gained `bridgeServer`,
  `siteLyrics`, `bridgeStatus`, `browsers` (and `browserPlayback` is live); `LyricsController.siteLyrics`;
  `LaunchOptions.bridgePort`, `bridgeWait`; `SmokeRunner.render(_:height:)`.

### For Step 8 (live wallpaper)

- **The song's video.** When the followed player is a YouTube Music or YouTube tab (`snapshot.track.source` is
  `.youtubeMusic` or `.youtube`), `snapshot.track.id` is its watch URL (`https://music.youtube.com/watch?v=<id>` or
  `https://www.youtube.com/watch?v=<id>`) and `BrowserSite.youtubeVideoID(snapshot.track.id)` gives the 11-character ID (the
  page's `getVideoData().video_id`, else the URL's `v`). Without the extension the system's guess carries no ID (search by
  artist and title instead). On YouTube Music the ID may be an "art track" (the album cover as a still): its player response
  says `videoDetails.musicVideoType` (`MUSIC_VIDEO_TYPE_ATV` art track, `_OMV` official video, `_UGC` upload); it is not
  sent yet — add a `musicVideoType` field to `BridgeTab` (older builds ignore unknown fields) and read it in
  `page/sites.js` (`ytResponse()`) if the wallpaper should prefer a real video.
- **Timing.** `snapshot.elapsed(at:)` follows the tab closely (reports on every seek and state change, every 30 s while
  playing, with the page's own sample time); an embedded muted video can be seeked to it. The tab plays the sound, so the
  wallpaper's player must stay muted.
- Plain YouTube videos are `.video`: the user watches them in the browser; the wallpaper (like the light) should not react.

### Known gaps and risks

- **The real sites were not opened** (no login, no contact with them; only the mock): the Media Session path is the common
  base and works anywhere; each site's extras (like, shuffle, repeat, search results, playlists, queue, lyrics responses) rely
  on today's page structure and may fail quietly when a site changes (the capability is then not offered, or a request answers
  "failed"). First real use: open each site, play, and watch `[bridge]` lines in the log and Settings › Sources.
- Sites' own lyrics arrive only when the site's lyrics view loads them (Spotify's lyrics button, YouTube Music's Lyrics tab).
- Search and play loads the site's search page in the tab: the current song stops for a moment; a site may block autoplay
  after the load ("press Play there").
- Search (WebKit) and Firefox were not tried (the rules forbid using the user's browsers; Playwright's Firefox does not load
  extensions this way). Search runs MAIN-world scripts and WebSockets through its own shims.
- Volume can be set on YouTube and YouTube Music (player API); elsewhere it is read from the page's slider and set on the
  media element, which a site may override.
- While Ahenk is closed, the extension retries every 30 s; Chromium may list the refused connections on the extension's
  Errors page.
- A local process (not a web page) can send any `Origin`; like any loopback service, the bridge trusts the Mac's own user.
- If a browser's network process cannot be found (it closed the socket at once), the browser is guessed from its reported
  name; with two Chromium browsers running, the guess can name the wrong one (only the icon and the tap target differ).

### What the user must do once

Install the extension in each browser (menu bar menu › **Install Browser Extension…** shows the folders and the steps):
Chrome, Edge, Brave or Arc: `chrome://extensions` › Developer mode › **Load unpacked** › `Ahenk.app/Contents/Resources/
Extension/Chromium`; the Search browser: the puzzle button › **Load Unpacked…** › the same folder; Firefox: `about:debugging`
› This Firefox › **Load Temporary Add-on…** › `Extension/Firefox/manifest.json` (again after each Firefox restart). Then open a
music site; the extension's button turns green and Settings › Sources lists the browser and its music tabs. No permission is
asked.

## Step 8 — Live wallpaper (done, 2026-11-09)

### What exists

```
Sources/AhenkKit/Models/SongVideoKind      YouTube's musicVideoType: officialVideo, userVideo, artTrack (the cover as a still), other
Sources/AhenkKit/Wallpaper/
  WallpaperCandidate    one thing to show (motion artwork, the song's video, another by the artist, the user's video, the
                        moving cover, generated motion) and how it plays (YouTube embed, AVPlayer stream or file, Ahenk-drawn)
  WallpaperRequest      the song as the wallpaper looks it up (the typed artist name, the tab's own video, the art-track rule)
  YouTubeSearch         YouTubeSearchDecoder (web client JSON or the results page's ytInitialData → YouTubeVideo),
                        YouTubeVideoSearch (keyless, cached, throttled; oEmbed embeddability)
  VideoRanking          the song's own video and the artist's other videos among search results
  MotionArtwork         MotionArtworkDecoder + MotionArtworkFinder (ported from DynamicIsland's AppleMotionArtwork)
  WallpaperStage        per display: melt in/out, front/back crossfade, play/pause/let go, hidden handling
  WallpaperSelection    the dots' order, the choice (pinned, picked, failed, waiting for a better source), WallpaperPowerPolicy
  VideoSync             follow the song (lengths close) or loop; start position; drift correction
  WallpaperCoverage     how much of a display other apps' windows cover
  YouTubeEmbed          the embedded player's page (IFrame API, privacy-enhanced host, the app's origin) and its messages
  WallpaperVideoList    the user's list: parse a link/address/file, add, show, rename, remove
  WallpaperSongStore    ~/Library/Application Support/Ahenk/WallpaperSongs.json: dot picks per song, typed names per artist
  WallpaperDemo         the demo's generated candidates and their colours
Sources/AhenkApp/Wallpaper/
  WallpaperController   inputs → lookups → per-display stages → windows and media; sync, coverage, status, the dots' model
  WallpaperWindow       WallpaperWindow (desktop picture level) + WallpaperScreenView (stage, blurred canvas, scrim, vignette)
  WallpaperMedia        WallpaperMediaView (base), SharedVideoPlayer (one AVPlayer per video for every display), VideoPlayerMediaView
  YouTubeMediaView      WKWebView with the embedded player: in-memory data store, mute guard in every frame, scaled for 1080p/720p
  MotionMediaViews      CoverMotionView (blurred drifting cover), GeneratedMotionView (demo looks, a band that follows the song)
  WallpaperPicker       the dots above the player and the artist name field (+ WallpaperSymbols)
  WallpaperCheck        smoke checks `wallpaper` and `wallpaperSwitch`
Sources/AhenkApp/Settings/Panes/WallpaperPane   the whole pane (sources, playback, look, displays, the user's videos)
Extension/              1.1.0: musicVideoType for YouTube Music and YouTube (C.musicVideoType; "- Topic" uploads are art tracks)
Tests/AhenkKitTests/    469 tests in 84 suites (was 434/72): WallpaperTests (search decoding, ranking, motion artwork, sync,
                        stage, selection, power, coverage, requests and art tracks, video IDs, the user's list, the song
                        store, the embed page, the demo), bridge fixtures with musicVideoType, layout, launch options
Tests/Extension/        24 node tests (was 23): the video type
```

How it plays: a song that the light would react to (music, or unlabelled content except on YouTube; never plain videos,
podcasts or adverts) starts a lookup: the YouTube tab's own video (when the page says it is a real video), the motion
artwork (Apple's catalog: the song's album through the player's ITunesCatalog, then `amp-api` with the web player's
anonymous token), the song's video and the artist's other videos (YouTube search), the cover. The dots list them in the
preferred order (motion artwork first by default; Settings › Live Wallpaper › First choice), the user's own videos after
them. What shows: a video pinned from the user's list, else the dot picked for this song, else the first that has not
failed; while a lookup for a better source runs, nothing is chosen for up to 3 s. A YouTube candidate is checked with
oEmbed once before it loads (401/403: embedding disabled → the next). On every display that shows the wallpaper, a
window at the desktop picture's level (`CGWindowLevelForKey(.desktopWindow)`, above the system's wallpaper windows,
below the icons, every Space, stationary, never clicked) is ordered in at opacity 0, the media loads under it and the
layer melts in over the crossfade time once it has frames (YouTube: 2.5 s after it plays, when its title has faded).
A new pick loads under the one showing and crossfades in. A pause keeps the frame 3 s, then the layer melts back to
the user's own wallpaper and everything is let go (or, with "Go back to your wallpaper" off, the paused frame stays).

### Build, run, verify

```sh
swift build && ./Scripts/test.sh      # 469 Swift tests + 24 node tests, no warnings
./Scripts/make-app.sh && ./Scripts/smoke.sh --snapshots   # wallpaper-*.png, desktop-wallpaper-dots-*.png, settings-wallpaper-full-*.png
./Scripts/bridge-e2e.sh               # also checks that the mock page's art-track type reaches the hub
open -n dist/Ahenk.app --args --demo --demo-backdrop      # generated "videos" over the dusk backdrop, the dots above the player
open -n dist/Ahenk.app --args --demo --draw-covered --demo-pause-after 12 --demo-resume-after 22   # melt back, come back
open -n dist/Ahenk.app --args --demo --draw-covered --wallpaper-song "<title>|<artist>" --wallpaper-source motionArtwork
open -n dist/Ahenk.app --args --demo --draw-covered --wallpaper-song "<title>|<artist>|<video seconds>" --wallpaper-source songVideo
pkill -x Ahenk
```

New launch arguments: `--wallpaper-song "<title>|<artist>[|<seconds>]"` (demo: the wallpaper looks up this real song
online while the demo plays; with a length the song's video follows the demo's position), `--wallpaper-source
<motionArtwork|songVideo|artistVideo|artwork|off>` (this kind first, or no wallpaper; in-memory settings), `--optimized`
(Optimized Mode for the run). `--draw-covered` also keeps the wallpaper playing under app windows (captures, measurements).

Smoke checks (all `ok`): `wallpaper` — per display a wallpaper window with the right level, Spaces and no clicks (never
ordered in); a WallpaperScreenView with two generated pictures crossfading, drawn offscreen before and after; the
moving cover from a generated demo cover; the state machine through a song; the embed page; the official video ranked
over the audio upload. `wallpaperSwitch` — the running controller with every display switched off in the in-memory
settings offers the demo song's four candidates, two dots are chosen and an artist name typed and forgotten, the menu
bar's Live Wallpaper item turns it off and on, and the dots are drawn in both languages. `resources` checks the new symbols.

Live checks on this Mac (2026-11-09; real media looked at only in /tmp and deleted, nothing of it in the repo): a real
album's motion artwork was found (token, iTunes, amp-api in ~1 s) and played (square cut over the 16:10 screen); the
song's official video was found by search, passed oEmbed and played in the embedded player muted, full screen, with no
YouTube chrome; with a length given it started at the demo's position and, when the demo jumped to the next song, was
"91.4 s off; moved to 0.1 s". The video element inside YouTube's frame reports muted, volume 0; the system's Now Playing
stayed empty while it played. Blur covers the web view too.

Measured on the M5 (release build, demo with the light (Soft Glow), the player and the lyrics (Fisheye) on, one 1512 × 982
display, `--draw-covered`; CPU = Ahenk plus every process it is responsible for: WebKit's WebContent, GPU and
Networking processes, the video decoder service), 20 s means:

| Wallpaper | CPU (all processes) | Of which outside Ahenk | Memory |
|---|---|---|---|
| off (baseline) | 7.6 % | — | Ahenk 144 MB |
| generated motion (demo) | 7.4 % | — | 144 MB |
| the moving cover | 7.7 % | — | 147 MB |
| motion artwork (AVPlayer, HLS) | 7.9–8.1 % | decoder 0.1–0.2 % | 157–170 MB + decoder 11 MB |
| YouTube embed, 1080p | 19.3–20.7 % | WebContent 4.4–4.6 %, GPU 4.2–4.5 %, Networking 0.7 %, decoder 2.1 % | 152–171 MB + WebContent 189 MB, GPU 25 MB, Networking 12 MB |
| YouTube embed, 720p (Optimized Mode) | 16.2 % | WebContent 3.6 %, GPU 3.6 %, Networking 0.2 %, decoder 2.3 % | 137 MB + WebContent 144 MB |
| YouTube song, desktop covered by windows (no `--draw-covered`) | 5.7 % (nothing loads) | — | 121 MB |
| paused, melted back (also after a YouTube video) | 0.00 % | 0.00 % (idle WebKit GPU/Networking stay) | 72–94 MB |
| live, nothing playing | 0.00 % | — | 31 MB |

So motion artwork costs ~0.3–0.5 % and the YouTube embed ~12–13 % (~9 % at 720p) on top of light + player + lyrics; the
window server (system-wide, noisy) read ~27–29 % with motion artwork or Ahenk's own motion and ~38–43 % with the embed.
Generated motion and the cover run as Core Animation in the window server at 30 fps (20 lighter, 15 in Low Power Mode).

### Decisions

- **Window level: the desktop picture's own** (`desktopWindow`, −2147483623 here). On macOS 26 the wallpaper itself is a
  window of the Wallpaper agent two levels lower and the Dock keeps a desktop window one level lower; the icons sit at
  `desktopIconWindow`. `ignoresMouseEvents`, so "click the wallpaper to reveal the desktop" still works. Not on
  full-screen Spaces (no `.fullScreenAuxiliary`). The user's wallpaper setting is never read or changed; quitting just
  closes the windows. The `--demo-backdrop` window moved one level under it and stands in for the user's wallpaper.
- **Finding videos without an account or key: YouTube's own web search endpoint** (`youtubei/v1/search`, client WEB,
  filter "videos", `gl` = the store country; Ahenk's normal User-Agent is accepted), with the results page's
  `ytInitialData` as a fallback (the "reject all" consent cookie `SOCS=CAI` avoids the consent screen some regions get).
  Evaluated and not used: the YouTube Data API (needs a key), Invidious/Piped instances (unreliable, often blocked),
  MusicBrainz/Wikidata video links (sparse), iTunes `musicVideo` previews (30 s clips, a different service). Each song
  costs at most two searches (the song: "<artist> <title> official video"; the artist: "<artist> official music video",
  shared by the artist's songs), cached a week (an empty answer a day) in `~/Library/Caches/Ahenk/Catalog`, at most 8
  requests a minute, 10 minutes of silence after a 429. Only titles, channels, IDs, lengths, badges, view counts and one
  bit of the description ("Provided to YouTube by …" = art track) are kept.
- **Ranking** (VideoRanking, checked on real answers for six songs in /tmp, never committed): the song's core title as
  whole words and the artist in the title or as the channel ("Artist", "ArtistVEVO", "Artist Official", the Official
  Artist Channel badge); never art tracks, "- Topic" channels, an artist channel's upload titled only with the track
  name, live streams, audio, lyrics, karaoke, slowed/sped-up/8D edits, loops, reactions, lessons, teasers; it must say it
  is a video (an official-video marker in several languages, or an official channel). Score: markers, official channels,
  a length close to the song's (an intro/outro costs little), views as a tie-breaker; live versions, remixes, acoustic
  takes, covers rank down. Artist videos: from the artist's channel (or naming the artist with a marker), 60 s–15 min,
  one per title, the song itself excluded.
- **Art tracks.** The extension now sends `musicVideoType` (YouTube Music and YouTube; a "- Topic" channel's upload is
  sent as an art track); the hub carries it as `NowPlayingSnapshot.songVideoKind`. A YouTube Music tab's video counts as
  the song's own only when the page says official video or upload (most songs there are art tracks; unknown counts as an
  art track); on YouTube a music page is a video unless the page says art track. Its ID is never searched for.
- **Motion artwork, ported**: the album comes from the player's own `ITunesCatalog.artist(for:)` (cached a month, shared
  with the cover flow) instead of a separate album search; the web player's token is read from `music.apple.com/us/new`'s
  script once, kept (memory and the catalog cache) until a day before its `exp`, and read again once on 401/403; answers
  cached a week, "none" three days. The square cut for landscape screens, the tall one for portrait screens.
- **The embedded player**: loaded with `loadHTMLString(_:baseURL:)` and the base URL `https://com.sinanmertsener.ahenk`
  (YouTube's "Required Minimum Functionality" for WebView apps: the bundle ID as the Referer; without it, error 153),
  the IFrame Player API with `host: www.youtube-nocookie.com`, `mute`, `controls 0`, `disablekb`, `fs 0`,
  `iv_load_policy 3`, `rel 0`, `playsinline`, `start`, `origin`; loops in the page (ENDED → seek 0) unless it follows
  the song; captions are unloaded (a muted player turns them on by itself). A user script in every frame keeps every
  media element muted at volume 0 and reports it; the player's errors 101/150 (embedding disabled), 100 (gone), 2, 5
  move to the next candidate, 152/153 and a failed script load (offline) give up on every YouTube candidate for the
  song; no `PLAYING` within 20 s is a failure. The web view uses `WKWebsiteDataStore.nonPersistent()` (nothing on disk),
  never navigates away (links, new windows refused) and never takes a click. Cover-fit: the player is 16:9 at the larger
  of the screen's width and height, centred and cut. Quality follows the player's size, so the web view is laid out
  smaller and scaled up: about 1080p, 720p on battery/Optimized Mode. One web view per display (a web view cannot be
  shared).
- **AVPlayer** for motion artwork, web addresses and files: one `SharedVideoPlayer` per video for every display (one
  decode), muted, `preventsDisplaySleepDuringVideoPlayback = false`, no AirPlay, no Now Playing; files loop seamlessly
  with `AVPlayerLooper`, streams by seeking to zero at the end; starts without waiting to minimise stalls, buffers 4 s;
  `preferredMaximumResolution` / `preferredPeakBitRate` from the power plan.
- **Following the song**: only the song's own video, only when the lengths are within 10 s or 6 %; it starts at the
  song's position plus the player's start-up (YouTube 1.5 s, AVPlayer 0.3 s), is compared every 4 s and after every seek or
  resume, and moved when more than 1.2 s off; past the video's end it holds. Everything else loops.
- **Hidden means**: asleep (`screensDidSleep`), locked or another user (`com.apple.screenIsLocked`, session resign), a
  full-screen app on that display (no full-screen Spaces; borderless full-screen windows via DesktopWatcher), occluded,
  or covered by windows: a desktop-level window is never "occluded" (the translucent menu bar and Dock show a strip of
  it), so while music plays Ahenk samples each display's usable area against other apps' window bounds every 2 s and on
  app/Space changes (no contents, no permission); ≥ 97 % covered counts as hidden. Hidden pauses at once and lets go after
  20 s; seen again, it loads and melts in.
- **Readability**: a uniform black scrim (Dimming, 15 % by default) and a radial vignette darker at the edges (for the
  edge light and the widgets), above the media and not blurred; Blur blurs a canvas that reaches past the screen's edges
  (and is clipped) so the desktop never shows at a soft edge.
- **Power**: full = 1080p, 30 fps motion; Optimized Mode or battery (with "run lighter on battery") = 720p at
  2.5 Mbit/s, 20 fps; Low Power Mode or a hot Mac = the cover only (no video decoding) unless the user picked a video.
- **The user's videos** stay in `AppSettings.wallpaper.savedVideos` (small, user-curated; a new `url` kind joins
  `youtube` and `file`); `selectedVideoID` pins one (shown while music plays, instead of the song's). Dot picks and typed
  artist names, which grow with listening, live in their own store.
- **Demo**: each demo song offers its own generated "video" (as long as the song, so it follows the song; a band of
  light crosses the screen once per song), two other looks and the cover; IDs are per song so every new song crossfades.

### Deviations from PLAN.md

- Beyond the plan: the user's own video list also takes web addresses of video files; the wallpaper also pauses under
  app windows (see Decisions); a "dots above the player" switch; launch arguments `--wallpaper-song`,
  `--wallpaper-source`, `--optimized`.
- Low Power Mode shows only the cover (the plan's "lighter"); Optimized Mode and battery lower the resolution.
- The picker dots are a row of the player window (`PlayerLayout.pickerHeight`), so the window grows 36 pt upwards
  when they are on; the bar stays where it was.
- **Shared API changes** (call sites and tests updated): `NowPlayingSnapshot.songVideoKind` (+ `differsNoticeably`, hub
  merge); `BridgeTab.musicVideoType`; `BrowserTabReport.songVideoKind`; `SavedVideo.Kind.url`; `WallpaperSettings`
  gained `preferredSource`, `blur`, `followSong`, `returnsOnPause`, `showPicker`, `disabledDisplays`;
  `PlayerLayoutState.showsWallpaperPicker`, `PlayerLayout.pickerHeight`; `DesktopPlayerModel.wallpaper`;
  `AppEnvironment.wallpaper`; `LaunchOptions` gained `wallpaperSongArgument`/`wallpaperSong`, `wallpaperSource`,
  `optimized` (and `usesDetachedSettings` covers the last two); the demo backdrop's window level; the extension is 1.1.0.

### For Step 9 (desktop extras)

- **Clear Desk** hides other apps; the wallpaper is Ahenk's own window and stays. With the apps hidden, the coverage
  check sees the desktop within 2 s and the wallpaper loads and melts in, which is what the feature wants. Ahenk's own
  windows never count as covering (owner PID check).
- **Stickers** on the desktop: windows at the widgets' level are above the wallpaper; nothing to do. A sticker window at
  the wallpaper's level would sit under it.
- **Local songs** (`.local`): `WallpaperRequest.follows` already accepts them (music or unlabelled); title and artist from
  the file's metadata are searched like any song. If the local player publishes `MPNowPlayingInfoCenter`, make sure the
  hub does not see Ahenk twice. Its AVQueuePlayer must not share the wallpaper's players (`SharedVideoPlayer` is muted
  and keyed by candidate ID).
- **Dock art** can read `environment.wallpaper.status`/`currentID` if the icon should hint at what shows.
- `WallpaperController.drawsWhenCovered` (`--draw-covered`) and `--wallpaper-song` make captures possible without music.

### Known gaps and risks

- **YouTube's embed rules.** YouTube's Required Minimum Functionality asks that nothing be drawn in front of an embedded
  player or obscure it and that a player autoplay only when more than half of it is visible. The wallpaper is muted and
  identifies itself as asked, but cover-fit cuts the player's edges, the scrim (Dimming) and the vignette sit over it, the
  desktop widgets and lyrics are above it, and captions are unloaded with the player's `unloadModule` (not in the
  documented API). Dimming at 0 shows the player unobscured apart from the widgets. YouTube may also limit embeds that
  make many requests.
- **Unofficial endpoints.** The YouTube search endpoint and the Apple Music web token are what the sites' own pages use,
  not published APIs; either can change shape or start refusing. Failures fall back quietly (other sources, the cover).
- No real music was played (the rules): lookups and playback were checked live with `--wallpaper-song` over the demo.
  Not tried live: an embedding-disabled video, a YouTube Music tab's official video through the extension, a portrait
  display, several displays, sleep and screen lock, Low Power Mode (the policy is unit-tested), a user's file or address.
- Two displays decode a YouTube video twice (one web view each); turn the second display off in Settings to save it.
- WebKit keeps its GPU and networking helpers alive (idle, 0 % CPU, ~37 MB) after the last web view went away.
- The embed's cost is high (~12 % CPU across helpers, more window-server work) compared with motion artwork (~0.5 %),
  which is why motion artwork is the default first choice.
- A song whose title and artist are generic can find another song's official video (ranked by title, artist and
  length; the dots can pick another or the artist can be typed).
- Motion artwork exists only for some albums; the album comes from Apple's catalog in the store country.

### What the user must do once

Nothing new is asked. To get the art-track signal from YouTube Music, reload the browser extension (1.1.0) from
`Ahenk.app/Contents/Resources/Extension` after installing this build.

## Step 9 — Desktop extras (done, 2026-11-10)

### What exists

```
Sources/AhenkKit/Desk/ClearDesk       DeskApp, ClearDeskState (the rules: clear → plan, restore → plan, refused / shown / quit),
                                      ClearDeskStore (a cleared desk on disk while it lasts), DeskSpaces (owners of full-screen Spaces)
Sources/AhenkKit/Dock/DockArt         DockArtPolicy (mode and frame rate; the cover's grace between songs), DockRingMotion (a swell
                                      per beat, the same at any frame rate), DockTileLook (the few steps a tile changes in),
                                      DockRingGeometry
Sources/AhenkKit/Stickers/            Sticker + StickerPlacement (free on a display, or stuck on a widget), StickerGeometry (window,
                                      clamping, snapping, new placements), StickerStore (Stickers.json + one PNG per cut-out)
Sources/AhenkKit/Local/               LocalSong + LocalFileNames (what a file's name and folders say), LocalLibraryScanner +
                                      LocalMetadata (tags, length, embedded cover, the folder's picture), LocalLibraryStore (remembered
                                      folders, bookmarks), LocalQueue (PlayQueue with a player's rules), GeneratedSongFiles (tones as
                                      WAV / tagged M4A for tests and checks)
Sources/AhenkKit/Audio/OwnAudioTap    Ahenk's own playback as samples for the analysis (+ OwnAudioPacer: bursts → a steady stream)
Sources/AhenkKit/Bridge/BrowserBridge LocalPlaybackEngine, LocalPlaybackProvider (the hub's "local" provider), SnapshotBroadcaster
Sources/AhenkKit/Demo/DemoStickerArt  generated "photos" (a mug, a ball on a studio backdrop) for the demo and the checks
Sources/AhenkApp/Desk/                ClearDeskController (+ DeskWorkspace: SystemDeskWorkspace, InventedDeskWorkspace; ManagedSpaces),
                                      ClearDeskCheck
Sources/AhenkApp/Dock/                DockArtController, DockTile (DockTileParts, DockTileRenderer, DockTileView), DockArtCheck
Sources/AhenkApp/Stickers/            StickerController, StickerWindow (+ StickerView: drag, resize, turn), StickerCutter (Vision),
                                      StickerCheck
Sources/AhenkApp/Local/               LocalPlayer (AVQueuePlayer + LocalPlayerEngine), LocalAudioTap (MTAudioProcessingTap → OwnAudioTap),
                                      LocalDemo (--demo-local), LocalCheck
Sources/AhenkApp/Desktop/Views/       ClearDeskButton (our own moon glyph), FileDrop (drops on widgets)
Settings                              Stickers pane (list, add, drop, remove), Desktop Player › Dock, Sources › Your Music Folders
Tests/AhenkKitTests/                  510 tests in 88 suites (was 469/84): ClearDeskTests, DockArtTests, StickerTests,
                                      LocalLibraryTests; hub, capture policy and launch option cases
```

**Dock art.** While a song the light would react to (music; never a video, a podcast or an advert) is followed and its
cover is known, `NSApp.dockTile.contentView` is a `DockTileView`: the round cover, a ring in the cover's colours that
swells on every beat, and the song's progress as a bright arc from the top. Playing: at most 10 tiles a second (6 in
Optimized Mode or on battery with "run lighter"); paused, the ring switched off, Low Power Mode or a hot Mac: one still
tile; nothing playing or Dock Art off: `contentView = nil`, Ahenk's own icon. Without the audio permission the ring
swells softly every 1.9 s while music plays. A new song's cover gets 3 s to arrive before the icon comes back (the last
cover stays meanwhile). Toggles: Settings › Desktop Player › Dock (`dock.albumArtIcon`, `dock.beatRing`) and the menu's
Dock Art.

**Clear Desk.** The menu bar item (and the Dock menu's) and the moon button beside the search field (above the small
player too) call `ClearDeskController.toggle()`. First click: Ahenk becomes active, then every visible regular app
except Ahenk is hidden with `NSRunningApplication.hide()`, back to front, the active app last; apps the user had hidden,
full-screen apps and menu bar extras are skipped. 1.2 s later, apps still visible count as refusing and are forgotten.
While cleared, an app the user shows (`didUnhideApplication`) or that quits is forgotten; apps launched meanwhile were
never recorded. Second click (and `applicationWillTerminate`, so also SIGTERM): `unhide()` for exactly the recorded
processes that still run (same PID and bundle) and are still hidden, back to front, then the app that was in front is
made active again. Nothing is ever quit, killed or relaunched, the Finder included. The state is written to
`~/Library/Application Support/Ahenk/ClearDesk.json` while the desk is cleared; a launch that finds one younger than 12 h
(a crash, a forced quit) shows those apps at once.

**Stickers.** A photo (open panel from Settings › Stickers, the player's ⋯ menu or a sticker's menu; or a picture file
dropped on Settings › Stickers or on any widget) is read at ≤ 2048 px, `VNGenerateForegroundInstanceMaskRequest` cuts
all its subjects out (the whole photo with rounded corners when Vision finds none), the cut-out is kept at ≤ 1024 px as
a PNG in `~/Library/Application Support/Ahenk/Stickers` next to `Stickers.json` (up to 60). Each sticker is a borderless
non-activating panel at the widgets' level (`desktopIconWindow + 1`, all Spaces, stationary), square so it turns inside
it, click-through outside the picture. Drag it anywhere on it, resize with the corner handle, a pinch or the scroll
wheel (48–640 pt, at most 90 % of the screen), turn it with the handle above it, a two-finger rotation or
Option-scroll (snaps to quarter turns within 3°). Right-click: Stick to the Clock / List / Player / Lyrics (it becomes a
child window of that widget, keeps its offset from the widget's anchor point, moves and hides with it), Leave on the
Desktop, Bring to Front, Original Size and Angle, Remove Sticker. A picture dropped on a widget sticks there. The
optional white die-cut border (`stickers.border`) is drawn at display time, not stored. Settings › Stickers lists them
with their place, frees or removes them, and reports what went wrong.

**Local songs.** A folder (or song files) dropped on Continue Playing or the player, or "Add Folder…" in the list's
menu or Settings › Sources: the folder is remembered (`LocalLibrary.json`, newest first, 40, with a bookmark that
follows a move), shown as the list ("Demo Tones · 3 songs") and played by `LocalPlayer`: an `AVQueuePlayer` holding the
current item and the next one (gapless), `LocalQueue` for the order. Tags, length and the cover come from the files
(ID3, iTunes, QuickTime; `cover.jpg`/`folder.png`… next to the song otherwise; the file's name and folders when there
are no tags). It reports to the hub as source `.local`, bundle `com.sinanmertsener.Ahenk`, with play/pause, next,
previous (restarts after 3 s), seek, shuffle and repeat off/all/one; the light, the lyrics chain, the wallpaper, Continue
Playing, the queue panel (Play Next, Add to Queue, remove, reorder), the play-the-list button and Dock art treat it like
any source. Outside the demo it publishes `MPNowPlayingInfoCenter` and takes the media keys; the system's report of
Ahenk merges into the same player (`KnownApps.ahenk` → `.local`), so the hub never sees Ahenk twice. With "pause the
previous source" on, starting song files pauses the other players and starting another source pauses the files.

**The light with Ahenk as the player.** No process tap can hear Ahenk (the taps exclude it on purpose), so every player
item carries an `MTAudioProcessingTap` (pre-effects, pass-through) whose process callback mixes the buffer to mono into
`OwnAudioTap`'s ring; `AudioCapturePolicy` answers a `.local` player with `.own(target)` (no permission needed) and the
analysis queue paces the tap's 4096-frame bursts into the usual pipeline (`OwnAudioPacer`). AVFoundation hands audio
over ~0.47 s before it is heard; `LocalPlayer` measures that lead from the player's clock in the first seconds of a
song and the features wait that long (`presentationDelay`).

### Build, run, verify

```sh
swift build && ./Scripts/test.sh      # 510 Swift tests + 24 node tests, no warnings
./Scripts/make-app.sh && ./Scripts/smoke.sh --snapshots   # dock-{still,calm,beat,view}.png, sticker-{cutout,turned}.png
open -n dist/Ahenk.app --args --demo --demo-backdrop      # Dock art (see the Dock), the mug sticker on the clock, the moon button
open -n dist/Ahenk.app --args --demo --demo-backdrop --demo-desk-cleared   # the invented desk cleared: the moon filled
open -n dist/Ahenk.app --args --demo --demo-backdrop --demo-local --draw-covered   # generated tones through the Local source, muted
swift Scripts/widget-shot.swift /tmp/desk.png --full      # Ahenk's own windows only
pkill -x Ahenk
```

New launch arguments: `--demo-local` (demo: three generated 50 s tones with generated covers in a temporary folder,
dropped on the desktop player like a user's folder and played by the local player with its volume at zero; deleted on
quit), `--demo-desk-cleared` (demo: Clear Desk on at launch, on the demo's invented apps), `--dock-art <on|still|off>`
and `--full-rate` ("run lighter on battery" off) for one run with in-memory settings (measurements on an unplugged
MacBook).

Tests by name. Clear Desk: "The first click hides every visible regular app but Ahenk, back to front, the active app
last", "The second click shows exactly what Ahenk hid…", "An app the user brings back meanwhile is theirs…", "An app
shown by the system without a notification is not shown twice", "Apps that quit, relaunch or start meanwhile are never
touched", "A reused PID with another bundle is not the app Ahenk hid", "An app that refuses to hide stays as it is and is
not restored", "Apps without windows on screen go first…", "Ahenk in front is never 'the app to bring back'; an empty
desk is a no-op", "The owners of full-screen Spaces are read from the list of Spaces, tiles of a split view included",
"A cleared desk is remembered on disk until it is restored, and only for a while". Stickers: placement on a display and
on a widget, dragging, new placements, size / rotation / window, encoding with a damaged placement, the store (order,
pictures, a lost picture, capacity). Local: file names for missing tags, track numbers, scanning generated files (tagged
M4A, untagged WAV, covers, album order), remembered folders following a move, the queue's rules (repeat, Next, Previous
after 3 s, shuffle kept, Play Next / Add to Queue, an unplayable file), the own tap's mixdown and the pacer. Dock: the
mode table, the cover's grace, the swell at 10 and 5 fps, the looks, frames that are not sent, the geometry inside the
tile. Hub: "Ahenk's own player and the system's report of Ahenk are one player…". Capture policy: `.own` for a local
player with and without the permission.

Smoke checks (28, all `ok`): `clearDesk` — the real controller on a desk of invented apps: Ahenk made active first,
Finder, Browser, Stubborn and Editor hidden in that order, the full-screen app, the hidden one and the menu bar extra
left alone, the refusing app let go after 1.2 s; after the user showed one, one quit and one started, the second click
only shows Editor and brings it to the front; the menu bar item toggles the environment's controller (invented apps in
smoke and demo runs; the check refuses to run otherwise). It also reads this Mac's apps and works the first click out
without carrying it out ("83 apps run, a click would hide 7 and leave 1 full-screen and 0 hidden ones alone").
`dockArt` — the tile from a generated cover drawn offscreen still, between beats and on a beat (cover in the middle,
clear corners, the ring's lit pixels 780 → 1381 → 4194), 33 of 40 frames sent in 4 s of the demo beat at 10 fps, and the
tile's own view drawn through every size of the swell (13 pictures; 0.7 ms a tile the first time, 0.04 ms afterwards).
`stickers` — a generated 1024 × 768 photo cut out by Vision in ~125 ms (360 × 301 px; backdrop and the hole in the mug's
handle clear), the white border, a sticker window at the widgets' level that can never become key, the turned sticker
drawn offscreen, the store. `localPlayback` — two tagged M4A tones and an untagged 48 kHz WAV generated into a temporary
folder, scanned (titles from tags and from a file name), played muted through `LocalPlayer` and a hub of its own; the
first song plays within ~35 ms, Ahenk's own audio reaches the analysis (44.1 kHz, energy 0.75, beats counted) with no
process tap, then Next, a seek and a pause are carried out and the analysis falls silent.

Seen in the demo (Ahenk's windows only, both languages): the mug sticker tilted on the clock's upper right corner; the
moon button outlined, and filled in the accent colour with `--demo-desk-cleared`; with `--demo-local` the list titled
"Demo Tones · 3 songs" with the files' covers, "Generated One — Demo Tones" in the bar, the cover as the wallpaper,
"No lyrics for this song", and in the log "Listening to Ahenk's own player (44100 Hz, 350 ms ahead of the sound)" and
"Dock icon: the cover with a beating ring".

Measured on the M5 (release build, on battery with `--full-rate`, demo with the light, the player and the lyrics on,
`--draw-covered --wallpaper-source off`, 30 s means with `top`; the user kept working, so Ahenk's own figure moves
between ~4 % and ~9 % from run to run with what the desktop shows):

| Dock art | Ahenk | Dock process |
|---|---|---|
| off | 6.8 %, 7.8 % (two runs) | 0.0–0.1 % |
| on, 10 fps | 4.1 %, 9.3 % (two runs) | 1.6–2.3 % |
| on, 6 fps (Optimized Mode / battery) | 6.5 % | 1.1–1.4 % |
| on, ring off or Low Power Mode (still) | 7.6 % | 0.0 % |
| on, paused (still) | 0.0–0.1 % | 0.0 % |
| the Local source playing (muted tones), Dock art on | 9.5 % | 1.2 % |
| live, nothing playing | 0.00–0.06 %, 34 MB | 0.0 % |

Ahenk's own share of the tile, by sampling its main thread for 6 s at 10 fps: 39 ms of 6 s (0.65 % of a core), where
the first version of the tile took 181 ms (3.0 %; +4.7 % by `top`). With lyrics, player and wallpaper off the pair read
6.1–6.2 % (off) against 5.8–7.6 % (on). The Dock's own cost per tile is not Ahenk's to cut; it follows the tile rate.

### Decisions

- **The tile is a few pictures, not a drawing.** The Dock's tile bitmap is 16-bit float wide colour; a conic gradient,
  a blurred shadow and a resampled cover drawn into it cost ~3 ms a tile (CPU frequency is low for sparse timer work).
  A picture drawn before is copied quickly (Core Graphics keeps its converted form). So the tile changes in steps
  (`DockTileLook`: paused, or 13 sizes of the swell × quiet/loud = 27 looks), each look is drawn once per cover into an
  8-bit picture of the tile's own pixels (cover on whole pixels), and a frame copies one picture and strokes the progress
  arc. Tried and dropped: wedges for the ring (60 fills were slower), drawing into an 8-bit canvas per frame and copying
  that (a new picture is converted every time), stroke rings for the glow. The ring's colours do not turn with the beat
  (a turned picture cannot be kept). Up to 27 × 256 KB per cover, made as needed.
- **The swell is timed from the beat, not from the frame.** `AudioFeatures.beat` lasts ~0.1 s, less than two frames at
  10 fps; `DockRingMotion` starts its own swell on every change of `beatIndex`, back-dated by `beatPhase`, decaying with
  0.16 s, so 10 and 6 fps show the same motion.
- **Only music takes the Dock icon** (the light's rule, `AudioCapturePolicy.reactsTo`): a paused video's thumbnail would
  otherwise sit in the Dock for as long as the browser tab stays open.
- **Clear Desk hides apps, not windows.** `NSRunningApplication.hide()`/`unhide()` is what Hide Others does: no
  permission, nothing to restore but "hidden" itself, window positions untouched. Ahenk activates itself first so macOS
  does not activate (and so show) an app that was just hidden. Desktop icons stay as they are (nothing covers them, and
  the Finder's settings are never touched).
- **Full-screen apps are left alone, and found through the list of Spaces.** Hiding the owner of a full-screen Space
  would have to switch Spaces on restore, and it does not cover the desktop. On this notched display a full-screen window
  is 1512 × 949 at y = 33, exactly like a zoomed window with the Dock hidden, so bounds cannot tell; the window server's
  `CGSCopyManagedDisplaySpaces` (SkyLight, private, looked up at run time, read-only) names each full-screen Space's
  owner (`type` 4, `pid`, split-view tiles under `TileLayoutManager.TileSpaces`). Without it, only a borderless window
  exactly as large as a display counts. An app with a full-screen window and a desktop window keeps both.
- **Demo and smoke runs can never hide anything.** `AppEnvironment` gives every run that is not `.normal` an
  `InventedDeskWorkspace` and an in-memory `ClearDeskStore`; the smoke check throws if it finds the real one.
- **A sticker is a window.** Windows give dragging between displays, per-sticker stacking, click-through outside the
  picture and child-window attachment for free; a hidden widget's stickers are ordered out, not closed. Placements are
  relative: to the display's visible frame (normalized) or to the widget's anchor point (points), and are clamped so the
  centre stays 12 pt inside a display.
- **Cut-outs: all instances, cropped to their extent**, downscaled to 1024 px, sRGB PNG. The border is CoreImage
  (morphology maximum + a small blur) at display time, so the setting applies to old stickers too.
- **The local player's ID is the file's path** (`Track.id`, `CatalogSong.origin.id` with source `.local`); lists carry
  song files as `CatalogSong`s and `DesktopPlayerModel.play` sends those to `LocalPlayer`, the rest to the queue
  conductor. Covers for `.local` come from the snapshot's `artworkData` (the catalog policy skips local songs); list rows
  read them from the file through `CoverImageStore`.
- **Folders are read each time** (tags of ≤ 4000 files, 8 at a time); only paths and bookmarks are stored.
- **Launch arguments for checks** stay demo-only or in-memory: `--demo-local` and `--demo-desk-cleared` do nothing
  without the demo; `--dock-art` and `--full-rate` never save.

### Deviations from PLAN.md

- Dock art also draws the song's progress on the ring and keeps the last cover for 3 s between songs.
- Clear Desk skips full-screen apps, apps the user had hidden and menu bar extras, and uses a private read-only window
  server call to find full-screen Spaces (see Decisions). Desktop icons are not covered while cleared.
- Stickers can also be turned, get an optional white border, and stick to the lyrics widget too.
- Local songs also take loose song files, play from the player widget too, and show in the system's Now Playing with
  media keys.
- **History.** One of the step's first commits used `KnownApps.ahenk` before a later commit defined it, so four commits
  did not build; the constant now arrives with its first use (the commits were not pushed yet; the final tree is the
  same). Every commit of the step builds and passes its tests.
- **Shared API changes** (call sites and tests updated): `AudioTapRequest.own`, `AudioEngineStatus.isOwnPlayback`;
  `AudioCaptureController.init(store:demo:ownAudio:)`, `AudioTapEngine.init(demo:ownAudio:)`;
  `LocalPlaybackProvider.init(engine:)` and `LocalPlaybackEngine`; `NowPlayingServices.live/demo(… local:)` (the demo's
  artwork provider now falls back to an offline pipeline, for local covers); `KnownApps.ahenk` (a music app of source
  `.local`); `QueueContext.folder` / `.droppedSongs`; `PlayQueue.removeCurrent(wrapping:)` and `following`;
  `ListSelection.folder`; `DesktopPlayerModel.local`, `library`, `onDropFiles`, `onAddSticker`;
  `DesktopPlayerController.onWidgetsChanged`; `QueueConductor.release()`; `DeskClearing` is implemented by
  `ClearDeskController` (`AppEnvironment.deskController`, `clearDesk`); `AppEnvironment.localPlayer`, `localLibrary`,
  `stickers`, `dockArt`; `LaunchOptions` gained `demoLocal`, `demoDeskCleared`, `dockArt`, `fullRate`.

### For Step 10 (sound effects and local lyric alignment)

- **Two kinds of player, two hooks.** External sources are heard through `ProcessTapSession` (Step 3): a private,
  **unmuted** tap whose C IOProc mixes every channel to mono into the analysis ring. Ahenk's own player is heard through
  `LocalAudioTap` (an `MTAudioProcessingTap` on each `AVPlayerItem`'s audio mix). `AudioCapturePolicy.request` says which
  (`.app`/`.everything` or `.own`), and `AudioEngineStatus.isOwnPlayback` tells the UI.
- **External sources.** Effects need the tap with `muteBehavior = .mutedWhenTapped` and the samples in stereo: give
  `ProcessTapSession` a second, stereo ring (keep the mono mixdown for the analysis, taken before the effects so the
  beat does not follow a reverb tail) and play that ring through an `AVAudioEngine` (`AVAudioSourceNode` → pitch → EQ →
  reverb → output). The tap already excludes Ahenk's own processes, so the processed sound is never tapped again; the
  aggregate device is clocked by an output-only device, use the same device for the engine to avoid drift. A muted tap
  unmutes by itself when Ahenk goes away; still unmute in `applicationWillTerminate` next to `audio.stop()`. Effects need
  the audio permission (no tap, no effects): say so in the UI. The "everything" fallback tap must never be muted.
- **Speed.** A live tap cannot play faster or slower than the source. Nightcore and Slowed need the player's own rate:
  browser tabs through the bridge (`BridgeTab.playbackRate` is already reported; a "set rate" command is new),
  the local player through `AVQueuePlayer.rate` with `audioTimePitchAlgorithm = .varispeed`; Apple Music and Spotify
  offer no rate, so there those presets can only shift pitch (say so, or hide them).
- **The Local player.** Its sound never passes a process tap, so effects go into its own chain. Simplest: process in
  place in `LocalAudioTap`'s `tapProcess` (stereo float, 4096 frames, the tap is created pre-effects and may modify the
  buffer: run the EQ / reverb / delay AudioUnits there, after `OwnAudioTap.Context.mix` has taken the dry signal), and
  use the player's rate for speed presets. Alternative: mute the `AVQueuePlayer` and feed the same `AVAudioEngine` chain
  as external sources from the tap; then delay by `OwnAudioTap.measuredLead` (~0.47 s), because the tap runs ahead of
  what is heard, or the lyrics and the light lead the sound. `LocalPlayer.makeSnapshot` reports `playbackRate` 1 or 0
  today; report the real rate so lyrics and the progress follow a sped-up song.
- **One switch for both.** `settings.effects` (enabled, preset, speed, pitch, reverb, equalizerEnabled, equalizerBands)
  exists since Step 1. Put the routing behind one controller that follows `nowPlaying.snapshot?.track.source` (`.local` →
  the player's chain, anything else → the muted tap + engine) and turns effects off when the followed player changes
  mid-song, so no source stays muted.
- **Lyric alignment.** For `.local` songs `Track.id` is the file's path: whisper-cli can read the file itself (convert
  with ffmpeg or `AVAssetReader` to 16 kHz mono first). For external sources there is no file; `LyricsSyncCapture`
  (Step 6) already records analysis audio in memory for the auto-sync and is the place to collect audio for alignment.
  Local songs get lyrics through the normal chain by title and artist (from tags, or the file name).
- **UI.** The sound effects button belongs beside the lyrics (`LyricsWidget`'s bar). `DesktopSymbols.all` must list any
  new SF Symbol (the `resources` smoke check). The player's ⋯ menu has "Add Sticker…"; stickers stuck to the lyrics
  widget are child windows of it, so a larger lyrics bar moves nothing.
- **Checks without sound.** `LocalPlayer(muted: true)` and `--demo-local` play at volume zero and still feed the tap
  (pre-effects); `GeneratedSongFiles` makes tones for tests. Never play test audio aloud on the user's Mac.

### Known gaps and risks

- **Clear Desk has never hidden a real app.** The rules, the controller, the menu and the buttons run against invented
  apps (tests, smoke, demo); the reading of this Mac's apps, window order and full-screen Spaces was exercised read-only.
  `hide()`, `unhide()`, `NSApp.activate()` from a click on a desktop-level widget, `yieldActivation(to:)` and the
  unhide/terminate notifications are untried on real apps. If Ahenk cannot become active first, macOS may show an app
  again when the front app hides; that app then counts as shown by the user and stays. First real use: click the moon
  with a few apps open and check the log (`[desk] Clear Desk: hid N apps (this Mac)`).
- An app that is full screen on one Space and has windows on the desktop is left alone entirely, so those windows stay.
  `CGSCopyManagedDisplaySpaces` is private; if it goes away, full-screen apps on notched displays are hidden like any
  other (macOS then keeps their Space and shows them again on restore).
- **The Dock itself was not looked at** (no full-screen captures): the tile is checked by drawing its view into a bitmap.
  The tile's bitmap is cleared before every frame in case the Dock does not.
- The Dock process costs ~1.6–2.3 % CPU at 10 tiles a second (1.1–1.4 % at 6); the ring can be switched off.
- No real photo was cut out (generated pictures only) and no real song file was played (generated tones, muted). Not
  tried: MP3 / FLAC / AIFF files, ID3 tags and embedded JPEG covers from real encoders, long folders, a DRM-protected
  file (skipped as unplayable by `isPlayable`), sample-rate changes between real songs, AirPlay or Bluetooth output (the
  lead is measured per song, clamped to 1.5 s), the media keys and the system's Now Playing for the local player (live
  mode only; the hub merge is unit-tested).
- Two player items (the current song and the preloaded next one) share one single-producer ring; if AVFoundation ever
  ran both taps at the same moment, a few analysis samples would be garbled around a song change (memory-safe, inaudible).
- Sticker gestures (drag, handles, pinch, rotation, context menu) and file drops on widgets were not driven by a real
  pointer; geometry, hit areas and persistence are unit-tested and the window is checked offscreen.
- Stickers are per Mac, not per display set: a sticker on a display that is gone moves to the first display.
- Local songs with invented or unknown artists show "The catalog does not know this artist" in the cover flow.
- Three launches during measurement ran in live mode by mistake (a shell quoting slip): Ahenk followed the system's Now
  Playing read-only for ~30 s each with in-memory settings and touched nothing else.

### What the user must do once

Nothing new is required. Song files need no permission for the light. To try Clear Desk for real, use the installed app
(not `--demo`, where the desk is invented).

## Step 10 — Sound effects and local lyric alignment (done, 2026-11-10)

### What exists

```
Sources/AhenkKit/Effects/             SoundEffectChain (what every stage does, from the settings; adapted to who controls the speed),
                                      SoundPreset.recipe + SoundEffectSettings.select / reset, SoundEcho, SoundOrbit, ReverbSpace,
                                      SoundOrbiter (8D: equal-power pan along a sine, in place), SoundEffectRouter (the route per
                                      player, when to switch off), SoundEffectTapRule (what a tap may mute)
Sources/AhenkKit/Lyrics/Alignment/    WhisperTranscript (whisper-cli's JSON → words with times), LyricAligner (plain lines × heard
                                      words → SyncedLyrics with word times; the fallbacks), WhisperLocator + WhisperTools (find the
                                      tool and a model, say what is missing), WhisperRunner (the command line, progress, cancel),
                                      WhisperAudio (16 kHz mono WAV from captured samples or a song file)
Sources/AhenkKit/Audio/AtomicSlots    lock-free 64-bit slots (numbers, doubles, pointers, a try-lock) for the audio threads
Sources/AhenkApp/Effects/             EffectsGraph (AVAudioEngine nodes: pitch → equalizer → echo → reverb), LocalEffectsProcessor
                                      (the graph inside Ahenk's own player, rendered by hand on its audio thread), EffectsOutput +
                                      ExternalEffects (the graph playing another app's muted sound to the output device),
                                      SoundEffectsController (one switchboard that follows the hub's player), SoundEffectsPanel
                                      (the panel beside the lyrics), EffectsCheck
Sources/AhenkApp/Lyrics/              LyricsAlignmentController (file / listening / demo, the tool and the model, ModelDownloader),
                                      LyricsAlignPanel, LyricsAlignmentCheck
Sources/AhenkApp/Audio/               ProcessTapSession(… effects:) (a muted tap that also hands the stereo sound on),
                                      AudioCaptureController.setEffects / setEffectsDelay / endLyricsCapture
Extension/ 1.2.0                      "rate" command and capability (C.playbackRate, C.rateCorrection); a tab gets its own speed
                                      back when Ahenk goes away
Settings                              Sound › Sound Effects (status, preset, speed, pitch, reverb, reset) and Equalizer;
                                      Lyrics › alignment (whisper-cli, speech model, Choose…, Download the Model)
Tests/AhenkKitTests/                  555 tests in 94 suites (was 510/88): SoundEffectTests (+ the real-time helpers),
                                      LyricAlignmentTests (transcript, aligner, tools, audio, the real tool when present),
                                      bridge rate cases; 25 node tests (was 24)
```

**Sound effects.** The slider button in the lyrics' bar (lit while the effects are on), "Sound Effects…" in the player's
⋯ menu and Settings › Sound all edit `settings.effects`. The panel over the lyrics: a status line, the presets as chips
(Custom, Nightcore, Slowed + Reverb, 8D Audio, Bass Boost, Echo, Vaporwave, Lo-fi, Concert Hall, Underwater), speed
(0.5–2×), pitch (±12 semitones), reverb, and ten vertical equalizer bands (32 Hz–16 kHz, ±12 dB) with Flatten, Reset and
the switch. Choosing a preset writes its values into the sliders (and switches the effects on); the parts no slider
reaches (the echo, the 8D orbit, the kind of room) stay with the preset until Custom is chosen. `SoundEffectChain` is
what the audio side reads: nothing at all while the switch is off.

`SoundEffectsController` follows `nowPlaying.snapshot` and routes (`SoundEffectRouter`):

- **Song files (`.local`)**: `LocalEffectsProcessor`, an `AVAudioEngine` in real-time manual rendering mode. The player's
  `MTAudioProcessingTap` callback hands the dry buffer to the analysis first, then, when `OwnAudioTap.effectsHook` holds a
  processor, runs the buffer through it in place (mono, separate or interleaved stereo floats). Speed is the player's own
  rate (`LocalPlayer.setSpeed`, `.varispeed`): the pitch follows the speed as on a record, and the pitch stage only does
  what is left (`SoundEffectChain.adapted(to: .ownPlayer)`: nothing for Nightcore, Slowed + Reverb and Vaporwave; the way
  back to the song's pitch when only the speed slider moved). The snapshot reports the real `playbackRate`, so the lyrics
  and the progress keep up; the tap hands audio over before the rate is applied, so the analysis is told the speed
  (`OwnAudioTap.playbackSpeed` → `analysisRate`).
- **Another app**: the capture's tap on that app is rebuilt with `muteBehavior = .mutedWhenTapped` and its IOProc also
  writes the stereo sound into a ring (`TapIOContext.feed`, whole chunks only); `EffectsOutput` (an `AVAudioSourceNode`
  reading the ring → the same graph → the output device) plays it. The mono analysis mix is taken from the same buffer
  before, so the light never follows an echo. The output is started before the tap is built and stopped after it is
  gone; if the output cannot start, or the tap runs at another rate than the clock device, the tap is built unmuted.
  A browser tab whose extension reports the `rate` capability takes the speed through the bridge
  (`BrowserBridgeServer.setRate`); the browser keeps the pitch, Ahenk shifts it. Apple Music, Spotify and other apps have
  no speed: the chain is adapted (`speed = 1`), the pitch still shifts, and the panel and Settings say "This player
  cannot change its speed, so only the pitch moves."
- **The demo**: an invented player with nothing to hear; the route is `.demo` and the UI says so. `--demo-local` routes
  to the real local chain (the player is muted).
- **Not possible** (the status line says why, with a button where there is something to press): system audio access not
  asked yet or denied, macOS older than 14.2, Ahenk hearing every app at once (the fallback tap: never muted), a video or
  a podcast, a player that cannot be told.

Nothing stays muted: `SoundEffectTapRule` lets a tap mute only the processes of the app the effects were asked for,
and only while Ahenk's output runs; a tap on everything, the demo and Ahenk's own player never are; the switch goes off
when another player (source + app) is followed than the one it was switched on for; `stop()` (in
`applicationWillTerminate`, so also on SIGTERM) removes the processor, asks the capture for an unmuted tap, puts the
tab's and the local player's speed back and switches the effects off; a run that ended without quitting finds the
switch on and turns it off before anything plays; an output that is interrupted three times in ten seconds gives the
app its own sound back; and the extension puts a tab's speed back when its connection to Ahenk closes. A muted tap
unmutes by itself when Ahenk's process goes away (Core Audio's rule, not Ahenk's).

**Lyric alignment (Beta).** "Align Lyrics" is a panel over the lyrics: the words on the left (the plain lyrics that were
found, or pasted and edited), on the right what is needed, the button and the progress. It opens from the wand button in
the lyrics' bar (shown while the song has plain, missing or failed lyrics), from the ⋯ menu (always, to time other words
again), and by itself after picking a "Words only" version in Search Lyrics (the list is where the right song is picked
when the match is uncertain). `LyricsAlignmentController`:

- **Song files**: `Track.id` is the path; `WhisperAudio.convert` reads the file with `AVAssetReader` into a 16 kHz mono
  WAV in the temporary folder.
- **Another app**: no file, so `LyricsSyncCapture` collects the analysis' mono audio (in memory) from now to the end of
  the song (at most 6 minutes; "Align Now" after 20 s); the song must play straight through at its own speed, which is
  checked against the snapshot before anything is recognised. The capture is resampled to 16 kHz and written the same
  way. Automatic sync steps aside meanwhile (`LyricsAutoSync.isSuspended`).
- **Recognising**: `whisper-cli -m <model> -f <wav> -l auto --output-json-full --max-len 1 --split-on-word
  --print-progress --dtw <preset> --no-flash-attn` (progress from stderr, the task's cancellation ends the process, 15
  minutes at most), the JSON read by `WhisperTranscript`. The preset is the model's name as whisper.cpp spells it
  (`ggml-large-v3-turbo-q5_0.bin` → `large.v3.turbo`); for a name it does not know, or when that run fails (an older
  whisper.cpp), the run is repeated without the last two arguments.
- **Timing** (`LyricAligner`): both sides reduced to bare words (case, accents, punctuation folded; ı as i; hyphenated
  words one by one), a dynamic-programming pairing in order where equal words score, nearly equal ones (edit distance)
  score less, neighbours in a row score extra and skips cost a little; lone short words are dropped. A line with heard
  words takes their times and gets word timings (unheard words spread between or beside the heard ones); a line without
  any is placed between its neighbours by its length (shared out when the room is about what the lines need, leading
  into the next heard line after a long stretch, squeezed in before the song ends) and carries no word timings.
  Quality: good (≥ 70 % of the lines heard), rough (≥ 30 %), failed (less: nothing is changed and the panel says how
  many lines were found).
- **Kept**: `LyricsFinder.adopt` stores the result under the song's choice key with the source `aligned` ("Timed on This
  Mac"), `timingAuthority = .canonicalRecording` (no automatic correction afterwards); "Use the Lyrics Ahenk Found"
  drops it.
- **The tool and the model**: `WhisperLocator` looks for `whisper-cli` / `whisper-cpp` in `/opt/homebrew/bin`,
  `/usr/local/bin`, `~/.local/bin`, `~/bin`, and for `ggml-*.bin` in `~/Library/Application Support/Ahenk/Models`,
  `~/Developer/whisper-models`, `~/whisper-models`, the whisper.cpp caches and Homebrew's share folders; the best model
  wins (larger first, every language before English only, full before compressed); `settings.lyrics.whisperExecutablePath`
  / `whisperModelPath` override both. What is missing is said in the panel and in Settings › Lyrics with Copy the Command
  (`brew install whisper-cpp`), Choose… and Download the Model (ggml-large-v3-turbo-q5_0.bin, 574 MB, into Ahenk's Models
  folder). Nothing is fetched unless that button is pressed.
- **The demo**: nothing to listen to; the demo song's own timing plays the recogniser and the real aligner times the
  words in the editor against it (the panel says so).

### Build, run, verify

```sh
swift build && ./Scripts/test.sh      # 555 Swift tests + 25 node tests, no warnings
./Scripts/make-app.sh && ./Scripts/smoke.sh --snapshots   # 30 checks; desktop-lyrics-{effects,align,align-working}-{en,tr}.png,
                                                          # settings-{sound,lyrics}-full-{en,tr}.png in ~/Library/Logs/Ahenk/snapshots
open -n dist/Ahenk.app --args --demo --demo-backdrop --demo-scene effects        # the effects panel, Slowed + Reverb on
open -n dist/Ahenk.app --args --demo --demo-backdrop --demo-scene align          # Align Lyrics with the demo song's words
open -n dist/Ahenk.app --args --demo --demo-backdrop --demo-scene align-working  # … at "Recognising the words… 40 %"
open -n dist/Ahenk.app --args --demo --demo-backdrop --demo-local --draw-covered --demo-scene effects   # the real local chain, muted
pkill -x Ahenk
```

New demo scenes: `effects`, `align`, `align-working`. No new launch arguments.

Tests by name. Effects: "Switched off, the chain does nothing whatever the sliders say", "Choosing a preset puts its
values into the sliders", "Sliders moved after a preset keep its echo and orbit; Custom drops them and keeps the
sliders", "Every preset but Custom changes something, stays inside the sliders' ranges and has ten bands", "A player
without a speed keeps its own; the pitch still shifts", "Ahenk's own player gains its pitch from the speed; the pitch
stage does what is left", "The orbit moves the sound from ear to ear at even loudness", "Song files go through Ahenk's
own chain, with or without the permission", "Another app goes through a muting tap, only with the permission", "Effects
are switched off when another player is followed, not between songs or tabs", "A tap mutes only the app the effects
were asked for, and only while Ahenk plays the sound", "The tap on every app, the demo and Ahenk's own player are never
muted". Bridge: "A speed for a tab has a wire form and stays within what a tab takes", the loopback server test sends
`setRate`; node: "the speed Ahenk asks a tab for". Alignment: "A word per segment: the segment's times, without markers
and sounds", "Longer segments: words are put together from their pieces", "With the attention's times a word ends where
the model heard it end, and a pause is not part of the next word", "Without them, a word that swallowed a pause is cut
to a plausible length", "Every line takes the time its first word was
sung; every word gets its own", "Misheard, swallowed and added words do not move the lines", "A refrain is timed where
it is sung, each time", "A line the recogniser missed sits between its neighbours, by its length", "After a long
instrumental stretch, missed lines lead into the next heard one", "Lines before the first and after the last heard one
stay in order and inside the song", "Audio that starts in the middle of the song gives song positions", "Another song's
words, or nothing heard, is a failure and keeps the lines in order", "Turkish lines match what a recogniser writes
without the dots and tails", "Whatever was heard, the lines stay in order and never share a start" (40 random
transcripts), "Aligned lyrics are kept like a picked version and come back with the song", the locator on invented
folders, model ranks, the command line, resampling, the WAV header, a generated song file converted, and "Spoken
invented lines are recognised and timed by the real tool" (runs only when this Mac has the tool and a model; `say -o`
writes a file and plays nothing).

Smoke checks (30, all `ok`; two are new):

- `soundEffects` — the processor the player's tap calls, on generated tones, measured and never played: the neutral
  chain returns the input exactly; Bass Boost lifts 64 Hz by 9.5 dB against 4 kHz without clipping; twelve semitones up
  put 880 Hz far over 440 Hz; the echo comes back 0.32 s after a burst with silence before it; the reverb leaves a tail;
  the orbit carries a tone 12× to each ear; all nine presets render (0.6 % of real time at most); the pitch stage delays
  by exactly 4096 frames, wired in but idle, and a shifted burst by 92 ms; a mono buffer and an interleaved one come out
  like two separate channels. Then a generated tone played by a muted `LocalPlayer` with the processor hooked in: its
  audio thread rendered 16–17 buffers, none left dry, the position moved at 0.83–0.85× for 0.85×, the tap handed audio
  over at 0.80–0.86× real time, and without the hook the song played on at 1×. Then another app's way without a tap or a
  device: `TapIOContext.feed` (interleaved and separate) → the ring → a silent `EffectsOutput` rendered by hand: silence
  until a buffer is in reserve, the buffers in order with left as left, silence when dry, a jump to the newest (keeping
  one in reserve) after half a second of backlog, the analysis' mono mix complete, a full ring taking no half chunk, Bass
  Boost in the way of the sound, and the pitch stage wired in and out while the engine runs. Last: the tap rule refuses
  the fallback tap and an output that does not run, and this run can neither make an `EffectsOutput` that plays nor a
  muted `ProcessTapSession` (both throw).
- `lyricAlignment` — the demo song's 16 invented lines timed against that song's own timing (±0.000 s heard in full; 16
  of 16 within 0.75 s with a third of the words missing and strays added); a generated M4A converted to 3.0 s of 16 kHz
  WAV; the download's mechanics from one temporary file to another (no network); the demo's controller timing the playing
  song's words, the result adopted as the song's lyrics (`aligned`, with word timings) and dropped again by "use the
  lyrics Ahenk found"; and, with the tool and model of this Mac, three invented lines spoken into a file by `say -o`:
  whisper-cli with ggml-large-v3-turbo-q5_0 recognised 19 words of 7.6 s in 1.5 s and the lines were timed at 0.0, 2.9 and
  5.7 s (the pauses in that file end at 3.08 and 5.81 s); then the same sound is fed through a `LyricsSyncCapture` as the
  analysis would hand it over (48 kHz in chunks, as from the middle of a song at 0:30), written, recognised and timed
  again: the lines land within 0.00 s of the first run plus 30 s. Without the tool this part is skipped and says what is
  missing.

Seen (offscreen snapshots of Ahenk's own views, both languages): the effects panel with "Demo: the effects are shown,
the demo's songs make no sound", the chips on two rows with Slowed + Reverb lit, Speed 0.85×, Pitch −3, Reverb 45 %,
the speed note, the equalizer with its ten bands and labels; Align Lyrics with the Beta badge, the song's words in the
editor, the explanation, the demo note and the button; the same at "Recognising the words… 40 %" with its bar and
Cancel; Settings › Sound and Settings › Lyrics in full (`/opt/homebrew/bin/whisper-cli`, `ggml-large-v3-turbo-q5_0.bin`,
Choose…). In the log of `--demo-local --demo-scene effects`: "Sound effects: in Ahenk's own player", "Song files play at
0.85× speed", "Sound effects run in Ahenk's own player (44100 Hz…)", and on SIGTERM "Song files play at 1.00× speed"
before "Quitting".

Measured on the M5 (release build, on battery, the user working, `--demo --demo-local --draw-covered --wallpaper-source
off`, `top`, 3 s samples): without effects 2.0–6.0 % and 135–180 MB; with Slowed + Reverb on and the panel open
4.1–8.0 % and 144–186 MB. The chain itself renders at 0.6 % of real time at most (smoke). With the switch off no engine,
no timer and no processor exists; the tap's callback reads one atomic slot.

### Decisions

- **One graph, three hosts.** `EffectsGraph` (pitch → equalizer → echo → reverb) is the same nodes whether an engine
  renders by hand inside the local player's tap, plays to the device for another app, or renders offline for a check.
  Speed is never a stage (only a player can play faster); the 8D orbit works on the samples before the engine
  (`SoundOrbiter`, Kit, tested), so it is the same everywhere.
- **The local player is processed in place**, not muted and replayed: the processed samples leave through the player, so
  the lyrics, the progress and the measured lead need nothing new, and nothing can be left muted. The engine is fed by
  an `AVAudioSourceNode` (pulled while it renders); the input node of a manual-rendering engine delivered the buffer one
  call late.
- **The pitch stage is wired in only while the pitch is shifted.** `AVAudioUnitTimePitch` holds the sound back by 4096
  frames even when bypassed, whatever the size of the render calls or the engine's maximum (measured). For song files
  a change from or to zero pitch swaps the processor; the device engine rewires while running. The light waits as long
  (`AudioTapEngine.setEffectsDelay`).
- **Song files change speed the way a record does** (`.varispeed`): no time stretching (the stretched player cost a
  few percent of CPU), and the classic sped-up and slowed sound. The chain is adapted so that the sliders still mean
  what they say: speed alone keeps the pitch (the stage shifts back), pitch alone shifts it.
- **A tab keeps its pitch** (the browser's default `preservesPitch`); Ahenk shifts it. The extension keeps the rate over
  song changes (sites reset it) and reports the element's real rate, so position interpolation stays right.
- **The capture mutes; the controller only asks.** The decision to mute sits next to the tap
  (`AudioCaptureController.build`): the output is started first, the rule is asked with what is true at that moment, and
  the stop order is tap first, output second. The UI learns through `AudioEngineStatus.playsEffects`.
- **Effects belong to the player and the run they were switched on for.** Another player (source + app) switches them
  off; so does quitting and starting. Presets and sliders are kept; the switch is not. A browser's tabs are one player
  (the rate follows the playing tab, the old tab gets its speed back).
- **Demo and smoke runs cannot mute or play.** `EffectsOutput.isAllowed` and `ProcessTapSession.mutingAllowed` are set
  from the launch mode once; both initialisers throw otherwise, and the smoke check tries. The silent `EffectsOutput`
  (manual rendering) is the same code with no device.
- **Word times come from the model's attention** (`--dtw`, the tokens' `t_dtw`), not from whisper's own word times.
  Measured on the spoken lines: whisper's own times put the first word after a second of silence where the word
  before it ended (1.90 s for a word spoken at 3.08 s) in one run and at the right place in another run of almost the
  same audio; `t_dtw` gave the same times in both (it marks where a token ends). So a word ends at its last piece's
  `t_dtw` and starts where the word before it ended, or a plausible word's length (0.1 s + 0.07 s a letter, 0.8 s at
  most) before its own end when that is later. That needs flash attention off, which makes whisper's encoder about twice
  as slow (0.70 s against 0.38 s for 30 s of audio here). Without `t_dtw` the same limit is put on whisper's own times.
  With a steady 110 Hz tone four times as loud as the voice mixed under the same spoken lines (by hand, outside the
  repo) `t_dtw` moved by 0.02 s at most; that is one tone under a synthetic voice, not a song.
  A word per segment (`--max-len 1 --split-on-word`) stays, for the fallback. No prompt with the lyrics is passed (it
  would invite the model to write the lyrics instead of hearing them).
- **Runs of words beat lone words.** The pairing rewards neighbours in a row (so a refrain is found where it is sung)
  and drops lone words of three letters or fewer. Lines that were not heard get no word timings, so the styles fall back
  to the line.
- **Aligned lyrics are a choice.** They live where a picked version lives (the choice key in the lyrics cache and the
  per-song store), so every existing path (the finder's order, "Use the Lyrics Ahenk Found", Clear) treats them right.
- **The model download is in the app but never automatic.** One button, in the panel and in Settings › Lyrics; a
  `URLSession` download into `~/Library/Application Support/Ahenk/Models`. Choose… works for any model or tool already
  on the Mac.
- **The effects button is lit while the effects are on**; the wand shows only where timing is what is missing.

### Deviations from PLAN.md

- **Not pushed.** The step's instructions were to commit locally and leave the push to the orchestrator.
- Song files are processed inside Ahenk's own player instead of through a tap (no tap can hear Ahenk, and none is
  needed).
- Three presets beyond the list: Lo-fi, Concert Hall, Underwater.
- The switch of the effects does not survive a run (see Decisions).
- Alignment also offers "Align Now" (a part of the song), word timings, and a model picker.
- `Scripts/widget-shot.swift` could not be used in this step: screen capture was denied to the shell the agent ran in
  (TCC, `SCStreamErrorDomain -3801`). The UI was checked through the offscreen snapshots of the smoke run instead.
- `Scripts/bridge-e2e.sh` was not run: its test browser plays a generated tone.
- **Shared API changes** (call sites and tests updated): `SoundPreset.underwater`; `SoundEffectSettings.select(_:)`,
  `reset()`, `matchesPreset`; `Comparable.clamped(to:)` is public; `AudioRingBuffer.Writer.free`, `Reader.skip(_:)`;
  `ahenk_compare_exchange`; `OwnAudioTap.effectsHook`, `playbackSpeed`, `analysisRate`, `Context.sampleRate`;
  `BridgeCapability.rate`, `BridgeCommand.Name.rate`, `BridgeCommand.rate`, `BridgeCommand(id:tabID:rate:)`,
  `BrowserBridgeServer.setRate(_:forTab:)`; `LyricsFinder.adopt(_:for:)`, `alignedSource`;
  `ProcessTapSession.init(scope:ring:effects:)`, `isMuted`, `mutingAllowed`; `TapIOContext.init(writer:stereo:scratchCapacity:)`,
  `feed(_:)`; `AudioEngineStatus.playsEffects`; `AudioCaptureController.setEffects`, `effectsInterrupted`,
  `setEffectsDelay`, `endLyricsCapture`; `AudioTapEngine.setEffects`, `effectsInterrupted`, `setEffectsDelay`,
  `stopListening(forLyrics:)`, `hearsEverything`; `LocalPlayer.speed`, `setSpeed(_:)`, items play with `.varispeed`, the
  snapshot's `playbackRate` is the speed; `LyricsController.Panel.effects` / `.align`, `adoptAligned`, `wordsToAlign`,
  and `choose` opens Align Lyrics after a plain pick; `LyricsWidget(… effects:audio:aligner:)`;
  `DesktopPlayerController.effects`, `audio`, `aligner`; `DesktopPlayerModel.onOpenSoundEffects`;
  `LyricsAutoSync.isSuspended`; `SoundPane(audio:effects:apps:settings:)`, `LyricsPane(… aligner:)`;
  `AppEnvironment.effects`, `aligner`; `ValueFormat.shortFrequency`; the extension is 1.2.0.

### For Step 11 (polish, performance, release)

- **Try the effects on a real app first** (see Known gaps): the muted tap and the device output have only run in
  pieces. `[audio] Listening to … muted and played with effects` and `[effects] Playing the app's sound with effects`
  are the lines to look for; `The effects' output could not start`, `no effects for this app` and `keeps being
  interrupted` are the failures. Tune the presets by ear (levels, `EffectsGraph.fullReverb`, the echo, the orbit's
  period); they were chosen from numbers.
- **Onboarding** should say that the browser extension must be reloaded (1.2.0) for the speed presets in tabs, and that
  the effects for other apps use the same system audio permission as the light.
- **Lyrics with the pitch stage** run 93 ms ahead of the sound (the light is compensated, the lyrics' clock is not);
  if it shows, add `appliedDelay` to the stage's clock.
- **Alignment** needs a pass with real songs: thresholds (`LyricAligner.goodLineShare`, `roughLineShare`,
  `fuzzyThreshold`), how long a whole song takes, whether `--max-len 1` word times hold up over music, and whether a
  vocal-forward pre-filter helps. The capture keeps a song's mono audio in memory (about 15 MB for four minutes).
- The Settings panes for Sound and Lyrics are complete for this step; the About pane's acknowledgements should name
  whisper.cpp as an optional tool the user installs (nothing of it is bundled).
- The feature list's items for QA: the effects button beside the lyrics, the presets by name, reverb, pitch, the
  ten-band equalizer, live toggling; Search lyrics → pick the song → aligned on the Mac, one download, Beta.
- **The test run stands still while it starts.** Every test waits about as long as every other at the start of a run
  (median test time 1.4–1.8 s before this step, 1.6–2.2 s after it, on a busy Mac). With this step's tests that reached
  the 2 s deadline of `eventually`, and "A start delay keeps the old song until the new one starts" failed in 8 of 32
  runs (0 of 19 before the step). `eventually` now waits up to 10 s (it still returns as soon as the condition holds);
  14 of 14 runs pass. What holds the run up was not looked for; it is worth finding in the performance pass.

### Known gaps and risks

- **The muted tap and the device output never ran on a real app.** Creating a muted tap on the user's music, or playing
  anything aloud, was ruled out for this step. Covered: the rules (unit tests), the hand-over, the ring, the source node,
  the effects and the rewiring (smoke, with no device). Not covered: `AudioHardwareCreateProcessTap` with
  `.mutedWhenTapped` (that the app really falls silent, at once, and comes back when the tap goes), `AVAudioEngine`
  starting on the control queue and playing to the default output, the gap or overlap at the moment of switching, the
  added latency by ear, an output device whose clock is not the tap's (the default output has an input stream, as some
  headsets do: the two then drift, and the output skips or waits now and then), AirPlay and Bluetooth, a change of
  output while playing (`AVAudioEngineConfigurationChange` → rebuild), the app's own volume control while muted, and
  multichannel sources (the first two channels are used).
- **Nothing was heard.** Every effect was measured, none listened to: presets may be too strong, too quiet or clip on
  real music (the equalizer takes 60 % of its largest boost off as headroom; echo and reverb add level on top).
- **The speed command never ran in a real browser.** The wire form, the server and the pure parts are tested; the page
  code (`setRate`, the correction in `read()`, the reset when Ahenk disconnects) is not. Sites that manage their own
  rate (YouTube's speed menu) will show another speed than they play; a site that fights the rate will flicker between
  the two.
- **Song files**: the preloaded next song's first buffers pass through the same processor (one buffer at a time, by a
  try-lock: a buffer that finds it busy stays dry), so a reverb tail carries over a song change and a click is possible
  there. Moving the pitch from or to zero swaps the engine and cuts a tail. Files in other layouts than mono or stereo
  floats are left dry (`LocalEffectsProcessor.skips` says why). The lead is measured again after a speed change; until
  then the light may be off by a few tens of milliseconds.
- **Alignment was only tried on a synthetic voice.** No song was recognised: whisper on singing over music misses and
  invents words, its word times are coarse, and instrumental parts can produce text. A line's first word that is held
  long after a pause starts late by about its hold (only its end is known; it is given a plausible word's length).
  The attention's times need a model whose name whisper.cpp knows (the usual `ggml-<size>[.en][-q…].bin`) and a
  whisper.cpp that has `--dtw`; otherwise whisper's own times are used, which smear pauses into the next word. The aligner's fallbacks are tested
  on invented transcripts, not on such output. Listening to another app was not tried with a real tap either (the
  capture is Step 6's; the checks for a pause or a seek are new and untested live). A song longer than 6 minutes is
  timed up to there; the rest is placed by length.
- **The model download never ran against its real address** (`WhisperLocator.suggestedModelURL`, 574,041,195 bytes
  expected; the size is that of the file on this Mac). Its mechanics ran on a local file. There is no checksum and no
  resume.
- **No pointer and no keyboard touched the new panels**: the sliders, the chips, the editor's focus in a desktop-level
  window and the open panels were not driven by hand; their layout was looked at in offscreen snapshots only, and
  `widget-shot.swift` was not available (see Deviations).
- The effects' switch is off after every launch; a listener who wants them always on has to press it each time.
- Effects for a source Ahenk follows only through the system's Now Playing work as for any app when its bundle is
  known; when only "every app" can be heard they are refused.
- `LyricsAlignmentController` and `SoundEffectsController` have no unit tests of their own (they are app code); their
  rules are in the Kit and their paths in the two smoke checks.

### What the user must do once

- **Effects for another app** need "System Audio Recording Only" for Ahenk (the permission the light already asks for).
  First real use: play a song, open the effects beside the lyrics, pick Bass Boost, and listen for a clean switch; then
  switch them off and quit Ahenk once while they are on, to see the app keep its own sound.
- **Speed presets in a browser tab**: reload the Ahenk extension (1.2.0) from the folder the menu shows.
- **Align Lyrics**: `whisper-cli` and a model are already on this Mac (`/opt/homebrew/bin/whisper-cli`,
  `~/Developer/whisper-models/ggml-large-v3-turbo-q5_0.bin`), so nothing is needed here. On another Mac: `brew install
  whisper-cpp`, then Download the Model in the panel or Choose… a model file.
