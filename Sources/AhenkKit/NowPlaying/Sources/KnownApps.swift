import Foundation

/// Bundle identifiers Ahenk recognizes. The app adds every browser it finds
/// on the Mac at run time (any app that opens https links), so this list
/// only has to cover the common ones and the special cases.
public enum KnownApps {
    public static let appleMusic = "com.apple.Music"
    public static let spotify = "com.spotify.client"
    /// "Search", a Chromium-based browser on the maintainer's Mac
    /// (`/Applications/Search.app`).
    public static let search = "com.officecommun.search"
    public static let safari = "com.apple.Safari"

    /// Desktop apps that are a music service of their own.
    public static let musicApps: [String: MusicSource] = [
        appleMusic: .appleMusic,
        spotify: .spotify,
        "com.tidal.desktop": .tidal,
        "com.deezer.deezer-desktop": .deezer,
        "com.deezer.Deezer": .deezer,
        "com.amazon.music": .amazonMusic,
        "com.amazon.AmazonMusic": .amazonMusic,
        // Community desktop apps for YouTube Music.
        "com.github.th-ch.youtube-music": .youtubeMusic,
        "com.github.th_ch.youtube_music": .youtubeMusic,
        "app.ytmdesktop.ytmdesktop": .youtubeMusic,
        "com.ytmdesktop.app": .youtubeMusic,
    ]

    public static let browsers: Set<String> = [
        safari,
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "com.google.Chrome.canary",
        "org.chromium.Chromium",
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "com.brave.Browser.nightly",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta",
        "com.microsoft.edgemac.Dev",
        "com.microsoft.edgemac.Canary",
        "company.thebrowser.Browser",
        "company.thebrowser.dia",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "com.operasoftware.OperaGX",
        "com.kagi.kagimacOS",
        "app.zen-browser.zen",
        "com.duckduckgo.macos.browser",
        search,
    ]

    /// Players whose content is video.
    public static let videoPlayers: Set<String> = [
        "org.videolan.vlc",
        "com.colliderli.iina",
        "io.mpv",
        "com.apple.QuickTimePlayerX",
        "com.apple.TV",
        "com.firecore.infuse",
    ]

    /// Players whose content is spoken word.
    public static let spokenWordPlayers: Set<String> = [
        "com.apple.podcasts",
        "com.apple.iBooksX",
        "com.apple.Books",
    ]

    /// Names to show when the app cannot be asked for its own (it quit).
    public static let displayNames: [String: String] = [
        appleMusic: "Apple Music",
        spotify: "Spotify",
        search: "Search",
        safari: "Safari",
        "com.apple.SafariTechnologyPreview": "Safari Technology Preview",
        "com.google.Chrome": "Google Chrome",
        "com.google.Chrome.beta": "Google Chrome Beta",
        "com.google.Chrome.dev": "Google Chrome Dev",
        "com.google.Chrome.canary": "Google Chrome Canary",
        "org.chromium.Chromium": "Chromium",
        "com.brave.Browser": "Brave",
        "com.microsoft.edgemac": "Microsoft Edge",
        "company.thebrowser.Browser": "Arc",
        "company.thebrowser.dia": "Dia",
        "org.mozilla.firefox": "Firefox",
        "com.vivaldi.Vivaldi": "Vivaldi",
        "com.operasoftware.Opera": "Opera",
        "com.kagi.kagimacOS": "Orion",
        "app.zen-browser.zen": "Zen",
        "com.duckduckgo.macos.browser": "DuckDuckGo",
        "com.tidal.desktop": "TIDAL",
        "com.deezer.deezer-desktop": "Deezer",
        "com.amazon.music": "Amazon Music",
        "org.videolan.vlc": "VLC",
        "com.colliderli.iina": "IINA",
        "com.apple.QuickTimePlayerX": "QuickTime Player",
        "com.apple.TV": "TV",
        "com.apple.podcasts": "Podcasts",
        "com.apple.iBooksX": "Books",
    ]
}
