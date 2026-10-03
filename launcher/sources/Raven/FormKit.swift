import AppKit

@MainActor
final class FormGrid {
    let gridView = NSGridView()
    var width: CGFloat = 420 {
        didSet { applyWidth() }
    }

    init() {
        gridView.translatesAutoresizingMaskIntoConstraints = false
        gridView.rowSpacing = 10
        gridView.columnSpacing = 10
        gridView.column(at: 0).xPlacement = .trailing
        gridView.setContentHuggingPriority(.required, for: .vertical)
    }

    var content: NSView { gridView }

    func labelRow(_ label: String, _ control: NSView) {
        let title = AppKitTheme.label(label, font: RavenType.caption(), color: .secondaryLabelColor)
        title.alignment = .right
        title.setContentHuggingPriority(.required, for: .horizontal)
        title.setContentCompressionResistancePriority(.required, for: .horizontal)
        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentHuggingPriority(NSLayoutConstraint.Priority(251), for: .horizontal)
        gridView.addRow(with: [title, control])
        applyWidth()
    }

    @discardableResult
    func fullRow(_ view: NSView) -> NSGridCell {
        view.translatesAutoresizingMaskIntoConstraints = false
        let row = gridView.addRow(with: [view, NSGridCell.emptyContentView])
        row.mergeCells(in: NSRange(location: 0, length: 2))
        applyWidth()
        return row.cell(at: 0)
    }

    @discardableResult
    func caption(_ text: String, color: NSColor = .secondaryLabelColor) -> NSTextField {
        let field = AppKitTheme.wrappingLabel(text, font: RavenType.caption(), color: color)
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        fullRow(field)
        return field
    }

    @discardableResult
    func errorLine() -> NSTextField {
        let field = AppKitTheme.wrappingLabel("", font: RavenType.caption(), color: .systemRed)
        field.isHidden = true
        fullRow(field)
        return field
    }

    func spacer(height: CGFloat = 6) {
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: height).isActive = true
        fullRow(box)
    }

    private func applyWidth() {
        guard gridView.numberOfColumns >= 2 else {
            if gridView.numberOfColumns == 1 {
                gridView.column(at: 0).width = width
            }
            return
        }
        let labelWidth: CGFloat = 110
        gridView.column(at: 0).width = labelWidth
        gridView.column(at: 1).width = max(width - labelWidth - gridView.columnSpacing, 100)
    }
}

@MainActor
class FormSheetViewController: NSViewController {
    let form = FormGrid()
    let actionRow = NSStackView()

    private(set) var defaultButton: NSButton?
    private var idleDefaultTitle = ""
    var onCancel: (() -> Void)?
    var onSubmit: (() -> Void)?

    weak var hostingSheet: NSWindow?

    var isValid: Bool = false {
        didSet { defaultButton?.isEnabled = isValid }
    }

    var sheetWidth: CGFloat {
        get { form.width }
        set { form.width = newValue }
    }

    override func loadView() {
        let container = NSView()
        form.gridView.translatesAutoresizingMaskIntoConstraints = false
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 10
        actionRow.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(form.gridView)
        container.addSubview(actionRow)
        NSLayoutConstraint.activate([
            form.gridView.topAnchor.constraint(equalTo: container.topAnchor, constant: RavenMetrics.spacing4),
            form.gridView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: RavenMetrics.spacing4),
            form.gridView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -RavenMetrics.spacing4),
            actionRow.topAnchor.constraint(greaterThanOrEqualTo: form.gridView.bottomAnchor,
                                          constant: RavenMetrics.spacing4),
            actionRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: RavenMetrics.spacing4),
            actionRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -RavenMetrics.spacing4),
            actionRow.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -RavenMetrics.spacing4),
        ])
        view = container
    }

    func configureFooter(defaultTitle: String,
                         defaultSymbol: String? = nil,
                         cancelTitle: String = "Cancel") {
        actionRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        actionRow.addArrangedSubview(spacer)

        let cancel = ClosureButton(title: cancelTitle) { [weak self] in
            self?.onCancel?() ?? self?.dismissForm()
        }
        cancel.keyEquivalent = "\u{1b}"
        actionRow.addArrangedSubview(cancel)

        let commit = ClosureButton(title: defaultTitle, symbol: defaultSymbol, prominent: true) { [weak self] in
            self?.onSubmit?() ?? self?.dismissForm()
        }
        commit.keyEquivalent = "\r"
        commit.isEnabled = isValid
        idleDefaultTitle = defaultTitle
        defaultButton = commit
        actionRow.addArrangedSubview(commit)
    }

    func setDefaultBusy(_ busy: Bool) {
        guard let button = defaultButton else { return }
        button.title = busy ? "Working…" : idleDefaultTitle
        button.isEnabled = busy ? false : isValid
    }

    func setDefaultTitle(_ title: String) {
        idleDefaultTitle = title
        defaultButton?.title = title
    }

    func recomputeSize() {
        preferredContentSize = view.fittingSize
    }

    func dismissForm() {
        guard let sheet = hostingSheet else {
            onCancel?()
            return
        }
        sheet.sheetParent?.endSheet(sheet)
    }
}

@MainActor
enum FormSheetPresenter {
    @discardableResult
    static func present(_ controller: FormSheetViewController,
                        title: String,
                        over parent: NSWindow? = nil,
                        onDismiss: (() -> Void)? = nil) -> Bool {
        guard let sheetParent = parent ?? NSApp.keyWindow ?? NSApp.mainWindow else { return false }
        controller.preferredContentSize = controller.view.fittingSize
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled]
        window.title = title
        controller.hostingSheet = window
        sheetParent.beginSheet(window) { _ in
            controller.hostingSheet = nil
            onDismiss?()
        }
        return true
    }
}

@MainActor
enum ConfirmSheet {
    static func destructive(title: String,
                            message: String,
                            confirmTitle: String,
                            style: NSAlert.Style = .warning,
                            over window: NSWindow? = nil,
                            onConfirm: @escaping () -> Void) {
        guard let parent = window ?? NSApp.keyWindow ?? NSApp.mainWindow else {
            onConfirm()
            return
        }
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: parent) { response in
            if response == .alertFirstButtonReturn {
                onConfirm()
            }
        }
    }
}
