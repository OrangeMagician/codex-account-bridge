import Foundation

private let cabInterfaceLanguageDefaultsKey = "interfaceLanguage.v1"

enum InterfaceLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case simplifiedChinese

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return cabLocalized("跟随系统")
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }

    var localeIdentifier: String {
        switch self {
        case .system:
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? ""
            return preferred.hasPrefix("zh") ? "zh-Hans" : "en"
        case .english:
            return "en"
        case .simplifiedChinese:
            return "zh-Hans"
        }
    }
}

private func cabCurrentInterfaceLanguage() -> InterfaceLanguage {
    guard let rawValue = UserDefaults.standard.string(forKey: cabInterfaceLanguageDefaultsKey),
          let language = InterfaceLanguage(rawValue: rawValue) else {
        return .system
    }
    return language
}

private func cabLocalizationBundle() -> Bundle {
    let localeIdentifier = cabCurrentInterfaceLanguage().localeIdentifier
    guard let resourcePath = Bundle.main.path(forResource: localeIdentifier, ofType: "lproj"),
          let bundle = Bundle(path: resourcePath) else {
        return .main
    }
    return bundle
}

func cabLocalized(_ key: String) -> String {
    NSLocalizedString(key, bundle: cabLocalizationBundle(), value: key, comment: "")
}
