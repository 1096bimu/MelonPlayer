import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by AetherPlayerApp; receives files opened from Finder / "Open With".
    /// Installing it flushes any URLs that arrived before the UI was ready.
    static var onOpenMainWindow: (() -> Void)?

    static var onOpenFiles: (([URL]) -> Void)? {
        didSet {
            guard onOpenFiles != nil, !pendingURLs.isEmpty else { return }
            let urls = pendingURLs
            pendingURLs = []
            deliver(urls)
        }
    }

    /// URLs from a cold-launch open that arrived before `onOpenFiles` was set.
    private static var pendingURLs: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        if AppDelegate.onOpenFiles != nil {
            AppDelegate.deliver(urls)
        } else {
            AppDelegate.pendingURLs.append(contentsOf: urls)
        }
    }

    /// Re-front the window when the app is reopened (e.g. Dock click) even
    /// when there are no visible windows.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        AppDelegate.bringToFront()
        return false // SwiftUI's scene opener owns recreation/fronting.

    }

    private static func deliver(_ urls: [URL]) {
        onOpenFiles?(urls)
        bringToFront()
    }

    /// Pull AetherPlayer to the foreground (and to the active Stage Manager
    /// set). Dispatched async so the window exists on a cold launch.
    static func bringToFront() {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            onOpenMainWindow?()
        }
    }
}
