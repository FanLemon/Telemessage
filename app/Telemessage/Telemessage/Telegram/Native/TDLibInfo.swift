import CTDJson
import Foundation

/// Synchronous TDLib calls that need no client instance (td_execute).
nonisolated enum TDLibInfo {
    static var version: String? {
        execute(["@type": "getOption", "name": "version"])?["value"] as? String
    }

    static func setLogVerbosity(_ level: Int) {
        _ = execute(["@type": "setLogVerbosityLevel", "new_verbosity_level": level])
    }

    private static func execute(_ request: [String: Any]) -> [String: Any]? {
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let result = td_execute(String(decoding: data, as: UTF8.self)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(String(cString: result).utf8))) as? [String: Any]
    }
}
