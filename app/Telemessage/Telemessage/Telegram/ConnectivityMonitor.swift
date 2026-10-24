import Cocoa
import Network

/// Keeps TDLib informed about the network and the user's presence:
/// - network type changes (and wake from sleep) so TDLib reconnects promptly;
/// - the `online` option while the app is active, as Telegram clients do.
final class ConnectivityMonitor {
    private let session: TelegramSession
    private let monitor = NWPathMonitor()
    private var tokens: [NSObjectProtocol] = []

    init(session: TelegramSession) {
        self.session = session
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let request: SetNetworkType = path.status != .satisfied ? .none : (path.usesInterfaceType(.wifi) ? .wifi : .other)
            Task { @MainActor in self?.session.post(request) }
        }
        monitor.start(queue: DispatchQueue(label: "com.Farsonic.Telemessage.network"))

        let workspace = NSWorkspace.shared.notificationCenter
        tokens.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.session.post(SetNetworkType.other) }
        })
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setOnline(true) }
        })
        tokens.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setOnline(false) }
        })
        setOnline(NSApp.isActive)
    }

    func stop() {
        monitor.cancel()
        for token in tokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            NotificationCenter.default.removeObserver(token)
        }
        tokens.removeAll()
    }

    private func setOnline(_ online: Bool) {
        session.post(SetOption(name: "online", value: .boolean(online)))
    }
}
