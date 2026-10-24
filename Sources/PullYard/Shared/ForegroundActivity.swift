import AppKit

@MainActor
enum ForegroundActivity {
    private static var token: NSObjectProtocol?
    private static var observers: [NSObjectProtocol] = []

    static func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { begin() }
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { end() }
        })
        if NSApp?.isActive == true { begin() }
    }

    private static func begin() {
        guard token == nil else { return }
        token = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "Interactive")
    }

    private static func end() {
        guard let token else { return }
        ProcessInfo.processInfo.endActivity(token)
        self.token = nil
    }
}
