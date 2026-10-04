import AppKit

final class RavenLifecycle: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ProviderStore.shared.flush()
        UsageStore.shared.stop()
        AccountsStore.shared.stop()
        Task { @MainActor in
            await CoreProcess.shared.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
