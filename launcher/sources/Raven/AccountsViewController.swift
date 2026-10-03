import AppKit

@MainActor
final class AccountsViewController: PanelScrollViewController, NSTextFieldDelegate, NSTextViewDelegate {
    private let store = AccountsStore.shared
    private let tracker = ObservationTracker()

    private let notice = PanelNoticeView()
    private let banners = NSStackView()
    private var bannerSignature = ""
    private var linkURLs: [ObjectIdentifier: String] = [:]

    private let ccSection = PanelSectionView(title: "Command Code")
    private let wbSection = PanelSectionView(title: "WorkBuddy")
    private let agSection = PanelSectionView(title: "Antigravity")

    private let ccTable = PanelReadTableView()
    private let wbTable = PanelReadTableView()
    private let agTable = PanelReadTableView()
    private var ccTableHeight: NSLayoutConstraint?
    private var wbTableHeight: NSLayoutConstraint?
    private var agTableHeight: NSLayoutConstraint?

    private var ccRows: [AccountView] = []
    private var wbRows: [AccountView] = []
    private var agRows: [AccountView] = []
    private var agColumns: [QuotaColumn] = []

    private var addFor: String?
    private var editTarget: String?
    private var addCaptcha = ""
    private var editCaptcha = ""

    private var ccAddButton: NSButton!
    private var wbAddButton: NSButton!
    private var wbRefreshButton: NSButton!
    private var agAddButton: NSButton!
    private var agRefreshButton: NSButton!

    private var addCCForm: NSView?
    private var addWBForm: NSView?
    private var addAGForm: NSView?
    private var editForm: NSView?

    private var addKeyField: NSSecureTextField?
    private var addEmailField: NSTextField?
    private var addPasswordField: NSSecureTextField?
    private var addTokenField: NSSecureTextField?
    private var addTokenRow: NSView?
    private var addTokenToggle: NSButton?
    private var addTurnstile: TurnstileView?
    private var addHint: NSTextField?
    private var addSubmitButton: NSButton?

    private var editKeyField: NSSecureTextField?
    private var editEmailField: NSTextField?
    private var editPasswordField: NSSecureTextField?
    private var editTokenField: NSSecureTextField?
    private var editTurnstile: TurnstileView?
    private var editHint: NSTextField?
    private var editSaveButton: NSButton?

    private var wbAuthText: NSTextView?
    private var wbNoteLabel: NSTextField?
    private var wbSubmitButton: NSButton?
    private var wbSignInButton: NSButton?
    private var wbReadLocalButton: NSButton?

    private var agCallbackField: NSTextField?
    private var agSignInButton: NSButton?
    private var agUseCallbackButton: NSButton?

    override func loadView() {
        super.loadView()
        for table in [ccTable, wbTable, agTable] {
            table.autoSortFirstSortableColumn = false
        }
        addFullWidth(notice)

        banners.orientation = .vertical
        banners.alignment = .leading
        banners.spacing = 8
        banners.isHidden = true
        addFullWidth(banners)

        addFullWidth(ccSection)
        addFullWidth(wbSection)
        addFullWidth(agSection)

        ccAddButton = smallButton("Add", symbol: "plus", action: #selector(addCCPressed))
        wbRefreshButton = smallButton("Refresh", symbol: "arrow.clockwise", action: #selector(refreshWBPressed))
        wbAddButton = smallButton("Add", symbol: "plus", action: #selector(addWBPressed))
        agRefreshButton = smallButton("Refresh", symbol: "arrow.clockwise", action: #selector(refreshAGPressed))
        agAddButton = smallButton("Add", symbol: "plus", action: #selector(addAGPressed))

        for table in [ccTable, wbTable, agTable] {
            table.tableView.rowHeight = 28
            table.tableView.columnAutoresizingStyle = .noColumnAutoresizing
            table.scrollView.hasHorizontalScroller = true
            table.scrollView.autohidesScrollers = true
        }

        ccTableHeight = ccTable.heightAnchor.constraint(equalToConstant: 120)
        wbTableHeight = wbTable.heightAnchor.constraint(equalToConstant: 120)
        agTableHeight = agTable.heightAnchor.constraint(equalToConstant: 120)
        ccTableHeight?.isActive = true
        wbTableHeight?.isActive = true
        agTableHeight?.isActive = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        render()
        tracker.start { [weak self] in
            guard let self else { return }
            _ = self.store.accounts
            _ = self.store.limits
            _ = self.store.wbStatus
            _ = self.store.agStatus
            _ = self.store.agQuota
            _ = self.store.error
            _ = self.store.fetchError
            _ = self.store.busy
            _ = self.store.wbOAuth
            _ = self.store.agOAuth
            self.render()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        tracker.resume()
        store.start()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        tracker.pause()
        store.stop()
    }

    private func render() {
        rebuildTags()
        notice.show(store.error ?? store.fetchError)
        renderBanners()
        renderCommandCode()
        renderWorkbuddy()
        renderAntigravity()
    }

    private func rebuildTags() {
        nameByTag = [:]
        nextTag = 1
        for account in store.accounts {
            _ = tag(for: account.name)
        }
    }

    private func renderBanners() {
        let signature = "\(store.agOAuth?.url ?? "")|\(store.wbOAuth?.url ?? "")"
        guard signature != bannerSignature else { return }
        bannerSignature = signature
        linkURLs = [:]
        banners.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let oauth = store.agOAuth {
            banners.addArrangedSubview(waitingBanner(text: "Waiting for the Google sign-in — finish it at accounts.google.com.",
                                                     url: oauth.url))
        }
        if let oauth = store.wbOAuth {
            banners.addArrangedSubview(waitingBanner(text: "Waiting for sign-in — complete the login at \(oauth.url).",
                                                     url: oauth.url))
        }
        banners.isHidden = banners.arrangedSubviews.isEmpty
    }

    private func waitingBanner(text: String, url: String) -> NSView {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.isSelectable = true
        let link = NSButton(title: "Open sign-in", target: self, action: #selector(openOAuthLink(_:)))
        link.bezelStyle = .inline
        link.controlSize = .small
        link.contentTintColor = .controlAccentColor
        linkURLs[ObjectIdentifier(link)] = url

        let row = NSStackView(views: [spinner, label, link])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .top
        row.edgeInsets = NSEdgeInsets(top: 10, left: RavenMetrics.spacing3, bottom: 10, right: RavenMetrics.spacing3)
        row.wantsLayer = true
        row.layer?.cornerRadius = 10
        row.layer?.borderWidth = 1
        row.layer?.borderColor = NSColor.separatorColor.cgColor
        row.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    @objc private func openOAuthLink(_ sender: NSButton) {
        guard let text = linkURLs[ObjectIdentifier(sender)], let url = URL(string: text) else { return }
        NSWorkspace.shared.open(url)
    }

    private func renderCommandCode() {
        ccRows = store.commandAccounts
        ccSection.setCount(ccRows.count)
        ccSection.setActions([ccAddButton])
        ccAddButton.title = addFor == "commandcode" ? "Close" : "Add"
        ccAddButton.image = AppKitTheme.symbol(addFor == "commandcode" ? "xmark" : "plus", pointSize: 11)
        ccAddButton.isEnabled = !store.busy

        var form: [NSView] = []
        if addFor == "commandcode", editTarget == nil {
            ensureAddCC()
            if let addCCForm { form.append(addCCForm) }
        }
        if let target = editTarget, let editable = store.accounts.first(where: { $0.name == target }),
           editable.provider == "commandcode" {
            ensureEditForm(editable)
            if let editForm { form.append(editForm) }
        }
        ccSection.setForm(form)

        updateAddCCGate()
        updateEditGate()
        updateTurnstileVisibility()

        if ccRows.isEmpty {
            ccSection.setBody(emptyState(symbol: "key.fill",
                                         title: "No Command Code accounts",
                                         hint: "Add an account with its API key — every enabled account joins the shared pool, drained one at a time.",
                                         action: #selector(addCCPressed),
                                         label: "Add Command Code account"))
            return
        }
        ccTable.configure(ccColumns())
        ccTable.reload(rowCount: ccRows.count)
        ccSection.setBody(ccTable)
        ccTableHeight?.constant = CGFloat(56 + ccRows.count * 30)
    }

    private func renderWorkbuddy() {
        wbRows = store.workbuddyAccounts
        wbSection.setCount(wbRows.count)
        wbSection.setActions([wbRefreshButton, wbAddButton])
        wbRefreshButton.isEnabled = !store.busy && !wbRows.isEmpty
        wbAddButton.title = addFor == "workbuddy" ? "Close" : "Add"
        wbAddButton.image = AppKitTheme.symbol(addFor == "workbuddy" ? "xmark" : "plus", pointSize: 11)
        wbAddButton.isEnabled = !store.busy

        if addFor == "workbuddy" {
            ensureAddWB()
            if let addWBForm { wbSection.setForm([addWBForm]) }
        } else {
            wbSection.setForm([])
        }

        wbSignInButton?.isEnabled = !store.busy && store.wbOAuth == nil
        wbSubmitButton?.isEnabled = !store.busy && !authJSONEmpty()
        wbReadLocalButton?.isEnabled = !store.busy

        if wbRows.isEmpty {
            wbSection.setBody(emptyState(symbol: "cpu",
                                         title: "No WorkBuddy accounts",
                                         hint: "Sign in with the browser flow, read the credential the CodeBuddy desktop app wrote on this machine, or paste the auth JSON.",
                                         action: #selector(addWBPressed),
                                         label: "Add WorkBuddy account"))
            return
        }
        wbTable.configure(wbColumns())
        wbTable.reload(rowCount: wbRows.count)
        wbSection.setBody(wbTable)
        wbTableHeight?.constant = CGFloat(56 + wbRows.count * 30)
    }

    private func renderAntigravity() {
        agRows = store.antigravityAccounts
        agSection.setCount(agRows.count)
        agSection.setActions([agRefreshButton, agAddButton])
        agRefreshButton.isEnabled = !store.busy && !agRows.isEmpty
        agAddButton.title = addFor == "antigravity" ? "Close" : "Add"
        agAddButton.image = AppKitTheme.symbol(addFor == "antigravity" ? "xmark" : "plus", pointSize: 11)
        agAddButton.isEnabled = !store.busy

        if addFor == "antigravity" {
            ensureAddAG()
            if let addAGForm { agSection.setForm([addAGForm]) }
        } else {
            agSection.setForm([])
        }

        agSignInButton?.title = store.agOAuth == nil ? "Sign in with Google" : "Restart sign-in"
        agUseCallbackButton?.isEnabled = canUseAGCallback()

        if agRows.isEmpty {
            agSection.setBody(emptyState(symbol: "sparkles",
                                         title: "No Antigravity accounts",
                                         hint: "Sign in with Google to reach the Gemini, Claude and GPT-OSS models Antigravity advertises for your account.",
                                         action: #selector(addAGPressed),
                                         label: "Add Antigravity account"))
            return
        }
        agColumns = AccountQuota.antigravityQuotaColumns(store.agQuota)
        agTable.configure(agQuotaColumns())
        agTable.reload(rowCount: agRows.count)
        agSection.setBody(agTable)
        agTableHeight?.constant = CGFloat(56 + agRows.count * 30)
    }

    private func smallButton(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = AppKitTheme.glassButton(title: title, symbol: symbol, prominent: false,
                                             action: action, target: self)
        button.controlSize = .small
        return button
    }

    private func emptyState(symbol: String, title: String, hint: String,
                            action: Selector, label: String) -> NSView {
        let button = AppKitTheme.glassButton(title: label, symbol: "plus", prominent: false,
                                             action: action, target: self)
        button.controlSize = .small
        return UnavailableView(symbol: symbol, title: title, description: hint, actions: [button])
    }

    @objc private func addCCPressed() { toggleAdd("commandcode") }
    @objc private func addWBPressed() { toggleAdd("workbuddy") }
    @objc private func addAGPressed() { toggleAdd("antigravity") }

    @objc private func refreshWBPressed() {
        Task { await store.refreshWorkbuddy() }
    }

    @objc private func refreshAGPressed() {
        Task { await store.refreshAntigravity() }
    }

    private func toggleAdd(_ provider: String) {
        if addFor == provider {
            addFor = nil
        } else {
            addFor = provider
            editTarget = nil
            addCaptcha = ""
            editCaptcha = ""
        }
        dropForms()
        render()
    }

    private func dropForms() {
        addCCForm = nil
        addWBForm = nil
        addAGForm = nil
        editForm = nil
        addKeyField = nil
        addEmailField = nil
        addPasswordField = nil
        addTokenField = nil
        addTokenRow = nil
        addTokenToggle = nil
        addTurnstile = nil
        addHint = nil
        addSubmitButton = nil
        editKeyField = nil
        editEmailField = nil
        editPasswordField = nil
        editTokenField = nil
        editTurnstile = nil
        editHint = nil
        editSaveButton = nil
        wbAuthText = nil
        wbNoteLabel = nil
        wbSubmitButton = nil
        wbSignInButton = nil
        wbReadLocalButton = nil
        agCallbackField = nil
        agSignInButton = nil
        agUseCallbackButton = nil
    }

    private func formCard(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: RavenMetrics.spacing3, left: RavenMetrics.spacing4,
                                        bottom: RavenMetrics.spacing3, right: RavenMetrics.spacing4)
        stack.wantsLayer = true
        stack.layer?.cornerRadius = 10
        stack.layer?.borderWidth = 1
        stack.layer?.borderColor = NSColor.separatorColor.cgColor
        stack.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        return stack
    }

    private func fieldRow(_ title: String, _ control: NSView) -> NSView {
        let label = AppKitTheme.label(title, font: .systemFont(ofSize: 11, weight: .medium), color: .secondaryLabelColor)
        let stack = NSStackView(views: [label, control])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        control.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    @discardableResult
    private func bindField<T: NSTextField>(_ field: T) -> T {
        field.delegate = self
        field.font = .systemFont(ofSize: 11)
        field.controlSize = .small
        return field
    }

    private func centered(_ control: NSView, trailing: Bool = false) -> NSView {
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(control)
        NSLayoutConstraint.activate([
            wrap.heightAnchor.constraint(equalToConstant: 22),
            control.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
            trailing
                ? control.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -2)
                : control.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
        ])
        return wrap
    }

    private func display(_ content: QuotaCellContent) -> (String, NSAttributedString?, String?) {
        switch content {
        case .dash:
            return ("—", nil, nil)
        case .badge(let text, let tip):
            return (text, PanelText.softBadge(text), tip)
        case .value(let percent, let reset, let title, let fraction):
            return (percent, PanelText.quotaValue(percent: percent, reset: reset, fraction: fraction), title)
        }
    }

    private func ccColumns() -> [PanelColumn] {
        var columns = [PanelColumn(title: "Account", width: 230) { self.ccRows[$0].name }]
        for period in UsagePeriod.allCases {
            columns.append(PanelColumn(title: period.header, width: 118) { row in
                self.display(self.ccQuota(row, period)).0
            } attributed: { row in
                self.display(self.ccQuota(row, period)).1
            } tooltip: { row in
                self.display(self.ccQuota(row, period)).2
            })
        }
        columns.append(PanelColumn(title: "Enabled", width: 74) { _ in "" } control: { row in
            self.enabledSwitch(self.ccRows[row])
        })
        columns.append(PanelColumn(title: "Actions", width: 78) { _ in "" } control: { row in
            self.ccActions(self.ccRows[row])
        })
        return columns
    }

    private func ccQuota(_ row: Int, _ period: UsagePeriod) -> QuotaCellContent {
        guard let limits = store.limitsByName(ccRows[row].name) else { return .dash }
        return AccountQuota.commandCodeCell(limits, period: period, first: period == .fiveHour)
    }

    private func wbColumns() -> [PanelColumn] {
        [
            PanelColumn(title: "Account", width: 200) { self.wbRows[$0].workbuddyNickname ?? "—" },
            PanelColumn(title: "UID", width: 160) { self.wbRows[$0].workbuddyUid ?? "—" }
                tooltip: { self.wbRows[$0].workbuddyUid },
            PanelColumn(title: "Credits", width: 110, alignsRight: true) { row in
                guard let status = self.store.wbStatusByUid(self.wbRows[row].workbuddyUid) else { return "—" }
                if status.cooling { return self.wbCoolingText(status) }
                return AccountQuota.creditsText(status.credits)
            } attributed: { row in
                guard let status = self.store.wbStatusByUid(self.wbRows[row].workbuddyUid),
                      status.cooling else { return nil }
                return PanelText.softBadge(self.wbCoolingText(status))
            } tooltip: { row in
                self.store.wbStatusByUid(self.wbRows[row].workbuddyUid)?.reason
            },
            PanelColumn(title: "Enabled", width: 74) { _ in "" } control: { row in
                self.enabledSwitch(self.wbRows[row])
            },
            PanelColumn(title: "Actions", width: 56) { _ in "" } control: { row in
                self.centered(self.trashButton(self.wbRows[row].name), trailing: true)
            },
        ]
    }

    private func wbCoolingText(_ status: WorkbuddyAccountStatus) -> String {
        guard let left = status.coolRemainingSec, left > 0 else { return "cooling" }
        return "cooling · \(left / 60):\(String(format: "%02d", left % 60))"
    }

    private func agAccountCell(_ row: Int) -> NSAttributedString? {
        guard store.agExpired(agRows[row].name) else { return nil }
        let name = NSAttributedString(string: agRows[row].name, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor,
        ])
        let spacer = NSAttributedString(string: " ")
        let badge = PanelText.softBadge("refreshing")
        let combined = NSMutableAttributedString()
        combined.append(name)
        combined.append(spacer)
        combined.append(badge)
        return combined
    }

    private func agQuotaColumns() -> [PanelColumn] {
        var columns = [
            PanelColumn(title: "Account", width: 150) { row in
                self.agRows[row].name
            } attributed: { row in
                self.agAccountCell(row)
            },
            PanelColumn(title: "Google account", width: 170) { row in
                self.agRows[row].antigravityEmail ?? "—"
            } tooltip: { self.agRows[$0].antigravityEmail },
        ]
        let quota = store.agQuota
        let names = agRows.map(\.name)
        let firstKey = agColumns.first?.key
        for column in agColumns {
            let cell: (Int) -> QuotaCellContent = { row in
                AccountQuota.antigravityCell(quota: quota.first { $0.name == names[row] },
                                             column: column,
                                             first: column.key == firstKey)
            }
            columns.append(PanelColumn(title: column.header, width: 108) { row in
                self.display(cell(row)).0
            } attributed: { row in
                self.display(cell(row)).1
            } tooltip: { _ in column.header })
        }
        columns.append(PanelColumn(title: "Enabled", width: 74) { _ in "" } control: { row in
            self.enabledSwitch(self.agRows[row])
        })
        columns.append(PanelColumn(title: "Actions", width: 56) { _ in "" } control: { row in
            self.centered(self.trashButton(self.agRows[row].name), trailing: true)
        })
        return columns
    }

    private var nameByTag: [Int: String] = [:]
    private var nextTag = 1

    private func tag(for name: String) -> Int {
        if let existing = nameByTag.first(where: { $0.value == name })?.key {
            return existing
        }
        let tag = nextTag
        nextTag += 1
        nameByTag[tag] = name
        return tag
    }

    private func enabledSwitch(_ account: AccountView) -> NSView {
        let toggle = NSSwitch()
        toggle.state = (account.disabled ?? false) ? .off : .on
        toggle.target = self
        toggle.action = #selector(switchToggled(_:))
        toggle.tag = tag(for: account.name)
        toggle.isEnabled = !store.busy
        toggle.controlSize = .small
        return centered(toggle)
    }

    private func trashButton(_ name: String) -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(rowButtonPressed(_:)))
        button.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        button.contentTintColor = .systemRed
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.toolTip = "Remove \(name)"
        button.tag = tag(for: name)
        button.isEnabled = !store.busy
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: RavenMetrics.minHitTarget).isActive = true
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: RavenMetrics.minHitTarget).isActive = true
        return button
    }

    private func ccActions(_ account: AccountView) -> NSView {
        let pencil = NSButton(title: "", target: self, action: #selector(editButtonPressed(_:)))
        pencil.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        pencil.contentTintColor = .secondaryLabelColor
        pencil.imagePosition = .imageOnly
        pencil.isBordered = false
        pencil.toolTip = "Edit \(account.name)"
        pencil.tag = tag(for: account.name)
        pencil.isEnabled = !store.busy
        pencil.widthAnchor.constraint(greaterThanOrEqualToConstant: RavenMetrics.minHitTarget).isActive = true
        pencil.heightAnchor.constraint(greaterThanOrEqualToConstant: RavenMetrics.minHitTarget).isActive = true
        let row = NSStackView(views: [pencil, trashButton(account.name)])
        row.orientation = .horizontal
        row.spacing = 10
        return centered(row, trailing: true)
    }

    @objc private func switchToggled(_ sender: NSSwitch) {
        guard let name = nameByTag[sender.tag],
              let account = store.accounts.first(where: { $0.name == name }) else { return }
        Task { await store.setEnabled(account, enabled: sender.state == .on) }
    }

    @objc private func rowButtonPressed(_ sender: NSButton) {
        guard let name = nameByTag[sender.tag] else { return }
        Task { await store.removeAccount(name) }
    }

    @objc private func editButtonPressed(_ sender: NSButton) {
        guard let name = nameByTag[sender.tag] else { return }
        addFor = nil
        editTarget = name
        editCaptcha = ""
        dropForms()
        render()
    }

    func controlTextDidChange(_ notification: Notification) {
        updateTurnstileVisibility()
        updateAddCCGate()
        updateEditGate()
        agUseCallbackButton?.isEnabled = canUseAGCallback()
    }

    private func authJSONEmpty() -> Bool {
        (wbAuthText?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func canUseAGCallback() -> Bool {
        !store.busy && store.agOAuth != nil
            && !(agCallbackField?.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
    }

    private func updateTurnstileVisibility() {
        if addFor == "commandcode", let turnstile = addTurnstile {
            let token = addTokenField?.stringValue.trimmingCharacters(in: .whitespaces) ?? ""
            let hidden = !token.isEmpty
            turnstile.isHidden = hidden
            addHint?.isHidden = hidden
        }
        if editTarget != nil, let editable = store.accounts.first(where: { $0.name == editTarget }),
           editable.provider == "commandcode", let turnstile = editTurnstile {
            let password = editPasswordField?.stringValue ?? ""
            let emailChanged = (editEmailField?.stringValue.trimmingCharacters(in: .whitespaces) ?? "") != (editable.email ?? "")
            let hidden = password.isEmpty && !emailChanged
            turnstile.isHidden = hidden
            editHint?.isHidden = hidden
        }
    }

    private func updateAddCCGate() {
        guard let submit = addSubmitButton, addFor == "commandcode" else { return }
        let email = addEmailField?.stringValue.trimmingCharacters(in: .whitespaces) ?? ""
        let token = addTokenField?.stringValue.trimmingCharacters(in: .whitespaces) ?? ""
        let key = addKeyField?.stringValue.trimmingCharacters(in: .whitespaces) ?? ""
        let password = addPasswordField?.stringValue ?? ""
        let usesToken = !token.isEmpty
        submit.isEnabled = !store.busy
            && !email.isEmpty
            && (usesToken || !key.isEmpty)
            && (usesToken || (!password.isEmpty && !addCaptcha.isEmpty))
    }

    private func updateEditGate() {
        guard let save = editSaveButton, let target = editTarget,
              let editable = store.accounts.first(where: { $0.name == target }) else { return }
        let emailChanged = (editEmailField?.stringValue.trimmingCharacters(in: .whitespaces) ?? "") != (editable.email ?? "")
        save.isEnabled = !store.busy && !(editable.provider == "commandcode" && emailChanged && editCaptcha.isEmpty)
    }

    private func ensureAddCC() {
        guard addCCForm == nil else { return }
        let key = bindField(NSSecureTextField())
        key.placeholderString = "user_…"
        let email = bindField(NSTextField())
        email.placeholderString = "you@example.com"
        let password = bindField(NSSecureTextField())
        let token = bindField(NSSecureTextField())
        addKeyField = key
        addEmailField = email
        addPasswordField = password
        addTokenField = token

        let toggle = NSButton(checkboxWithTitle: "Use a session token instead",
                              target: self, action: #selector(toggleTokenPath(_:)))
        toggle.controlSize = .small
        toggle.font = .systemFont(ofSize: 11)
        addTokenToggle = toggle

        let hint = NSTextField(wrappingLabelWithString: "Complete Command Code verification before signing in. Password is stored in accounts.json for session renewal.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.isSelectable = true
        addHint = hint

        let turnstile = TurnstileView()
        addTurnstile = turnstile
        turnstile.onToken = { [weak self] value in
            self?.addCaptcha = value
            self?.updateAddCCGate()
        }

        let submit = AppKitTheme.glassButton(title: "Add account", symbol: "plus", prominent: true,
                                             action: #selector(submitAddCC), target: self)
        submit.controlSize = .small
        addSubmitButton = submit
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelForms))
        cancel.bezelStyle = .rounded
        cancel.controlSize = .small
        let buttons = NSStackView(views: [submit, cancel])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let tokenRow = fieldRow("Session token", token)
        addTokenRow = tokenRow
        tokenRow.isHidden = true

        addCCForm = formCard([
            fieldRow("API key", key),
            fieldRow("Command Code email", email),
            fieldRow("Command Code password", password),
            toggle,
            tokenRow,
            hint,
            turnstile,
            buttons,
        ])
        updateAddCCGate()
    }

    @objc private func toggleTokenPath(_ sender: NSButton) {
        addTokenRow?.isHidden = sender.state != .on
        updateTurnstileVisibility()
        updateAddCCGate()
    }

    @objc private func submitAddCC() {
        guard addFor == "commandcode" else { return }
        let email = addEmailField?.stringValue.trimmingCharacters(in: .whitespaces) ?? ""
        let key = addKeyField?.stringValue.trimmingCharacters(in: .whitespaces)
        let password = addPasswordField?.stringValue
        let token = addTokenField?.stringValue.trimmingCharacters(in: .whitespaces)
        let captcha = addCaptcha
        Task { [weak self] in
            guard let self else { return }
            let ok = await self.store.signInCommandCode(name: email, key: key, email: email,
                                                       password: password, sessionToken: token,
                                                       captcha: captcha)
            if ok {
                self.addFor = nil
                self.addCaptcha = ""
                self.dropForms()
                self.render()
            }
        }
    }

    @objc private func cancelForms() {
        addFor = nil
        editTarget = nil
        addCaptcha = ""
        editCaptcha = ""
        dropForms()
        render()
    }

    private func ensureEditForm(_ account: AccountView) {
        guard editForm == nil else { return }
        let key = bindField(NSSecureTextField())
        key.placeholderString = account.hasKey == true ? "Saved API key (leave blank to keep)" : "user_…"
        let email = bindField(NSTextField())
        email.stringValue = account.email ?? ""
        let password = bindField(NSSecureTextField())
        password.placeholderString = account.hasPassword == true ? "Saved password (leave blank to keep)" : ""
        let token = bindField(NSSecureTextField())
        editKeyField = key
        editEmailField = email
        editPasswordField = password
        editTokenField = token

        let turnstile = TurnstileView()
        editTurnstile = turnstile
        turnstile.onToken = { [weak self] value in
            self?.editCaptcha = value
            self?.updateEditGate()
        }

        let save = AppKitTheme.glassButton(title: "Save", symbol: "checkmark", prominent: true,
                                           action: #selector(submitEdit), target: self)
        save.controlSize = .small
        editSaveButton = save
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelForms))
        cancel.bezelStyle = .rounded
        cancel.controlSize = .small
        let buttons = NSStackView(views: [save, cancel])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        var rows = [
            fieldRow("API key", key),
            fieldRow("Command Code email", email),
            fieldRow("Command Code password", password),
        ]
        if account.provider != "commandcode" {
            rows.append(fieldRow("Session token", token))
        }
        rows.append(editHintView(turnstile))
        rows.append(buttons)
        editForm = formCard(rows)
        updateTurnstileVisibility()
        updateEditGate()
    }

    private func editHintView(_ turnstile: TurnstileView) -> NSView {
        let label = NSTextField(wrappingLabelWithString: "Complete Command Code verification before signing in or updating the email.")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.isSelectable = true
        editHint = label
        let stack = NSStackView(views: [label, turnstile])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return stack
    }

    @objc private func submitEdit() {
        guard let target = editTarget,
              let editable = store.accounts.first(where: { $0.name == target }) else { return }
        let emailValue = editEmailField?.stringValue.trimmingCharacters(in: .whitespaces) ?? ""
        let key = editKeyField?.stringValue.trimmingCharacters(in: .whitespaces)
        let password = editPasswordField?.stringValue
        let token = editTokenField?.stringValue.trimmingCharacters(in: .whitespaces)
        let captcha = editCaptcha
        let emailChanged = emailValue != (editable.email ?? "")
        let wantsSignIn = editable.provider == "commandcode"
            && (!(password?.isEmpty ?? true) || !(token?.isEmpty ?? true) || (emailChanged && !captcha.isEmpty))

        if wantsSignIn {
            Task { [weak self] in
                guard let self else { return }
                let ok = await self.store.signInCommandCode(name: target, key: nil, email: emailValue,
                                                            password: password, sessionToken: token,
                                                            captcha: captcha)
                if ok {
                    self.editTarget = nil
                    self.editCaptcha = ""
                    self.dropForms()
                    self.render()
                }
            }
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let ok = await self.store.editAccount(name: target, key: key, sessionToken: token,
                                                  email: nil, password: password, disabled: nil)
            if ok {
                self.editTarget = nil
                self.dropForms()
                self.render()
            }
        }
    }

    private func ensureAddWB() {
        guard addWBForm == nil else { return }
        let label = AppKitTheme.label("Auth JSON (or sign in)", font: .systemFont(ofSize: 11, weight: .medium),
                                      color: .secondaryLabelColor)
        let local = NSButton(title: "Read from local", target: self, action: #selector(readWBLocal))
        local.bezelStyle = .rounded
        local.controlSize = .small
        wbReadLocalButton = local

        let header = NSStackView(views: [label, local])
        header.orientation = .horizontal
        header.distribution = .fill
        label.setContentHuggingPriority(.required, for: .horizontal)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 84))
        text.minSize = NSSize(width: 0, height: 84)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.containerSize = NSSize(width: 320, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.isRichText = false
        text.allowsUndo = true
        text.delegate = self
        scroll.documentView = text
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 96).isActive = true
        wbAuthText = text

        let note = AppKitTheme.label("", font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        wbNoteLabel = note

        let submit = AppKitTheme.glassButton(title: "Add WorkBuddy", symbol: "plus", prominent: true,
                                             action: #selector(submitAddWB), target: self)
        submit.controlSize = .small
        wbSubmitButton = submit
        let signIn = NSButton(title: "Sign in", target: self, action: #selector(startWBSignIn))
        signIn.bezelStyle = .rounded
        signIn.controlSize = .small
        wbSignInButton = signIn
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelForms))
        cancel.bezelStyle = .rounded
        cancel.controlSize = .small
        let buttons = NSStackView(views: [submit, signIn, cancel])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        addWBForm = formCard([header, scroll, note, buttons])
        wbSubmitButton?.isEnabled = !store.busy && !authJSONEmpty()
        wbSignInButton?.isEnabled = !store.busy && store.wbOAuth == nil
    }

    func textDidChange(_ notification: Notification) {
        wbSubmitButton?.isEnabled = !store.busy && !authJSONEmpty()
    }

    @objc private func submitAddWB() {
        let auth = wbAuthText?.string.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !auth.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            let ok = await self.store.addWorkbuddy(authJson: auth)
            if ok {
                self.addFor = nil
                self.dropForms()
                self.render()
            }
        }
    }

    @objc private func startWBSignIn() {
        addFor = nil
        Task { await store.startWorkbuddyOAuth() }
    }

    @objc private func readWBLocal() {
        wbNoteLabel?.stringValue = ""
        Task { [weak self] in
            guard let self else { return }
            guard let result = await self.store.readWorkbuddyLocal() else { return }
            if result.found, let json = result.authJson, !json.isEmpty {
                self.wbAuthText?.string = json
                let who = result.nickname ?? result.uid ?? "account"
                let source = result.source.map { " from \($0)" } ?? ""
                self.wbNoteLabel?.stringValue = "Loaded \(who)\(source)"
                self.wbSubmitButton?.isEnabled = !self.store.busy
            }
        }
    }

    private func ensureAddAG() {
        guard addAGForm == nil else { return }
        let hint = NSTextField(wrappingLabelWithString: "Sign in opens Google in a new tab and catches the redirect on localhost:51121. On a machine without a browser, open the link yourself and paste the whole callback URL back here.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.isSelectable = true

        let callback = bindField(NSTextField())
        callback.placeholderString = "http://localhost:51121/oauth-callback?state=…&code=…"
        callback.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        agCallbackField = callback

        let signIn = AppKitTheme.glassButton(title: store.agOAuth == nil ? "Sign in with Google" : "Restart sign-in",
                                             symbol: "sparkles", prominent: true,
                                             action: #selector(startAGSignIn), target: self)
        signIn.controlSize = .small
        agSignInButton = signIn
        let use = NSButton(title: "Use pasted callback", target: self, action: #selector(submitAGCallback))
        use.bezelStyle = .rounded
        use.controlSize = .small
        agUseCallbackButton = use
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelForms))
        cancel.bezelStyle = .rounded
        cancel.controlSize = .small
        let buttons = NSStackView(views: [signIn, use, cancel])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        addAGForm = formCard([hint, fieldRow("Callback URL (optional)", callback), buttons])
        agUseCallbackButton?.isEnabled = canUseAGCallback()
    }

    @objc private func startAGSignIn() {
        Task { await store.startAntigravityOAuth() }
    }

    @objc private func submitAGCallback() {
        guard let session = store.agOAuth?.session else { return }
        let callback = agCallbackField?.stringValue.trimmingCharacters(in: .whitespaces) ?? ""
        guard !callback.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            let ok = await self.store.completeAntigravity(session: session, callback: callback)
            if ok {
                self.addFor = nil
                self.dropForms()
                self.render()
            }
        }
    }
}
