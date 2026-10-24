import Foundation

/// User preferences that apply to the whole app (not to one account).
final class AppSettings {
    static let shared = AppSettings(defaults: .standard)

    private let defaults: UserDefaults
    private var observers: [UUID: () -> Void] = [:]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        defaults.register(defaults: [Key.notifications: false, Key.previews: false, Key.autoDownloadPhotos: true])
    }

    private enum Key {
        static let notifications = "notificationsEnabled"
        static let previews = "notificationPreviews"
        static let autoDownloadPhotos = "autoDownloadPhotos"
    }

    /// Off until the user turns it on; turning it on asks macOS for permission.
    var notificationsEnabled: Bool {
        get { defaults.bool(forKey: Key.notifications) }
        set { set(newValue, Key.notifications) }
    }

    /// Message text in notifications; off by default for privacy.
    var notificationPreviews: Bool {
        get { defaults.bool(forKey: Key.previews) }
        set { set(newValue, Key.previews) }
    }

    var autoDownloadPhotos: Bool {
        get { defaults.bool(forKey: Key.autoDownloadPhotos) }
        set { set(newValue, Key.autoDownloadPhotos) }
    }

    func observe(_ handler: @escaping () -> Void) -> StoreObservation {
        let id = UUID()
        observers[id] = handler
        return StoreObservation { [weak self] in self?.observers[id] = nil }
    }

    private func set(_ value: Bool, _ key: String) {
        guard defaults.bool(forKey: key) != value else { return }
        defaults.set(value, forKey: key)
        for observer in observers.values { observer() }
    }
}
