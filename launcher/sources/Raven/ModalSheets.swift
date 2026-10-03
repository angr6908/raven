import AppKit

enum ModalSheet {
    static func window(content: NSViewController, title: String, size: NSSize) -> NSWindow {
        let window = ModalSheetWindow(contentViewController: content)
        window.styleMask = [.titled, .closable, .resizable]
        window.titlebarSeparatorStyle = .automatic
        window.isReleasedWhenClosed = false
        window.title = title
        window.setContentSize(size)
        window.contentMinSize = NSSize(width: min(size.width, 460), height: min(size.height, 260))
        return window
    }
}

@MainActor
final class ModalSheetWindow: NSWindow {
    var onDismiss: (() -> Void)?

    override func close() {
        super.close()
        let dismiss = onDismiss
        onDismiss = nil
        dismiss?()
    }
}
