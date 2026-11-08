import AhenkKit
import Foundation

/// UI text with an in-app language switch (English by default, Turkish on
/// request, independent of the system language).
///
/// Keys ARE the English text, so English needs no lookup and a missing
/// Turkish entry falls back to English instead of showing a key. The
/// LocalizationCoverageTests keep `tr.lproj/Localizable.strings` complete.
///
/// Turkish rule: never glue a fixed suffix onto a variable ("%@'da" is wrong
/// for half the words). Rephrase so no suffix is needed.
enum L10n {
    /// The Turkish table, or nil (then everything stays English).
    static let turkish: Bundle? = {
        guard let path = ResourceBundle.bundle?.path(forResource: "tr", ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }()

    @MainActor
    static var language: AppLanguage {
        AppEnvironment.current?.settings.general.language ?? .english
    }

    /// Locale for dates and numbers in the current UI language.
    @MainActor
    static var locale: Locale { language.locale() }

    @MainActor
    static func string(_ key: String) -> String {
        guard language == .turkish, let turkish else { return key }
        return turkish.localizedString(forKey: key, value: key, table: nil)
    }

    /// `String(format:)` on the translated key, with the UI locale.
    @MainActor
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: locale, arguments: arguments)
    }

    /// Number of Turkish entries, for diagnostics.
    static var turkishEntryCount: Int {
        guard let url = turkish?.url(forResource: "Localizable", withExtension: "strings"),
              let table = NSDictionary(contentsOf: url)
        else { return 0 }
        return table.count
    }
}

extension String {
    /// This English text in the current UI language.
    @MainActor
    var l10n: String { L10n.string(self) }
}
