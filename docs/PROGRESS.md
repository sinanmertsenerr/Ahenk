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
