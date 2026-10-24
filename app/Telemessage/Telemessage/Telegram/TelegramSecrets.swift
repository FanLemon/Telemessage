import Foundation

/// Telegram API credentials from the bundled, gitignored TelegramSecrets.plist.
nonisolated struct TelegramSecrets: Sendable {
    let apiID: Int
    let apiHash: String

    enum LoadError: LocalizedError {
        case missing
        case invalid

        var errorDescription: String? {
            switch self {
            case .missing:
                "TelegramSecrets.plist is missing. Copy Config/TelegramSecrets.example.plist to Telemessage/TelegramSecrets.plist."
            case .invalid:
                "TelegramSecrets.plist needs an integer APIID and a string APIHash."
            }
        }
    }

    static func load(from bundle: Bundle = .main) -> Result<TelegramSecrets, LoadError> {
        guard let url = bundle.url(forResource: "TelegramSecrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url) else { return .failure(.missing) }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let apiID = plist["APIID"] as? Int,
              let apiHash = plist["APIHash"] as? String, !apiHash.isEmpty
        else { return .failure(.invalid) }
        return .success(TelegramSecrets(apiID: apiID, apiHash: apiHash))
    }
}
