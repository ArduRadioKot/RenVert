import Foundation

/// Resolves UI strings in the language picked in Settings.
///
/// `String(localized:)` on its own uses the language the process started with, so a change
/// in Settings would only show after a relaunch. Lookups here go through the `.lproj` of the
/// selected language instead and follow the setting at once.
public enum Localization {
    private static let lock = NSLock()
    private static var base: Bundle = .main
    private static var resolved: Bundle = .main
    private static var code = "en"

    /// `base` is the bundle that holds the `.lproj` folders: the app bundle, or the resource bundle under SwiftPM.
    public static func configure(base: Bundle, language: AppLanguage) {
        let code = language == .system ? systemLanguage(in: base) : language.rawValue
        let resolved = base.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)) ?? base
        lock.lock()
        self.base = base
        self.resolved = resolved
        self.code = code
        lock.unlock()
    }

    public static func setLanguage(_ language: AppLanguage) {
        lock.lock()
        let base = self.base
        lock.unlock()
        configure(base: base, language: language)
    }

    public static var bundle: Bundle {
        lock.lock()
        defer { lock.unlock() }
        return resolved
    }

    /// Locale for plural rules and for date and number formatting in the selected language.
    public static var locale: Locale {
        lock.lock()
        defer { lock.unlock() }
        // Keep the user's region so dates and numbers stay in their format.
        if let region = Locale.current.region?.identifier {
            return Locale(identifier: "\(code)_\(region)")
        }
        return Locale(identifier: code)
    }

    /// The app writes its own `AppleLanguages` override, so the system order is read from the global domain.
    private static func systemLanguage(in base: Bundle) -> String {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        let preferred = (global?["AppleLanguages"] as? [String]) ?? Locale.preferredLanguages
        let available = base.localizations.filter { $0 != "Base" }
        return Bundle.preferredLocalizations(from: available, forPreferences: preferred).first ?? "en"
    }
}

/// Localized string in the language selected in Settings.
public func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: Localization.bundle, locale: Localization.locale)
}
