import AppKit

final class RavenLifecycle: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        ProviderStore.shared.flush()
        UsageStore.shared.stop()
        AccountsStore.shared.stop()
    }
}
