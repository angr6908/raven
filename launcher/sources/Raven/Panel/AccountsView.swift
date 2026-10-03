import AppKit
import SwiftUI

private let accountsPageState = AccountsPageState()

@Observable
final class AccountsPageState {
    var addFor: String?
    var editTarget: String?

    var addKey = ""
    var addEmail = ""
    var addPassword = ""
    var addToken = ""
    var useTokenPath = false
    var addTurnstile: TurnstileController?

    var editKey = ""
    var editEmail = ""
    var editPassword = ""
    var editToken = ""
    var editTurnstile: TurnstileController?

    var wbAuthJson = ""
    var wbNote = ""
    var agCallback = ""

    var ccTable = DataTableState()
    var wbTable = DataTableState()
    var agTable = DataTableState()

    func toggleAdd(_ provider: String) {
        if addFor == provider {
            addFor = nil
        } else {
            addFor = provider
            editTarget = nil
        }
        resetForms()
    }

    func beginEdit(_ name: String) {
        addFor = nil
        editTarget = name
        resetForms()
    }

    func cancelForms() {
        addFor = nil
        editTarget = nil
        resetForms()
    }

    private func resetForms() {
        addKey = ""
        addEmail = ""
        addPassword = ""
        addToken = ""
        useTokenPath = false
        addTurnstile = nil
        editKey = ""
        editEmail = ""
        editPassword = ""
        editToken = ""
        editTurnstile = nil
        wbAuthJson = ""
        wbNote = ""
        agCallback = ""
    }

    var addCaptcha: String { addTurnstile?.token ?? "" }
    var editCaptcha: String { editTurnstile?.token ?? "" }
}

struct AccountsView: View {
    private let store = AccountsStore.shared
    @Bindable private var page = accountsPageState

    var body: some View {
        PanelPage {
            PanelNotice(message: store.error ?? store.fetchError)
            banners
            commandCodeSection
            workbuddySection
            antigravitySection
        }
        .onAppear { store.start() }
        .onDisappear { store.stop() }
    }

    private func sectionCard<Actions: View, Form: View, Body: View>(
        _ title: String, count: Int,
        @ViewBuilder actions: () -> Actions,
        @ViewBuilder form: () -> Form,
        @ViewBuilder body: () -> Body
    ) -> some View {
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Pill(text: String(count))
                    Spacer(minLength: 8)
                    actions()
                }
                form()
                body()
            }
        }
    }

    private var banners: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let oauth = store.agOAuth {
                waitingBanner("Waiting for the Google sign-in — finish it at accounts.google.com.", url: oauth.url)
            }
            if let oauth = store.wbOAuth {
                waitingBanner("Waiting for sign-in — complete the login at \(oauth.url).", url: oauth.url)
            }
        }
    }

    private func waitingBanner(_ text: String, url: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.system(size: 12))
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button("Open sign-in") {
                if let link = URL(string: url) { NSWorkspace.shared.open(link) }
            }
            .controlSize(.small)
            .buttonStyle(.link)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 1) }
    }

    private var commandCodeSection: some View {
        let rows = store.commandAccounts
        return sectionCard("Command Code", count: rows.count) {
            Button(page.addFor == "commandcode" ? "Close" : "Add",
                   systemImage: page.addFor == "commandcode" ? "xmark" : "plus") {
                page.toggleAdd("commandcode")
            }
            .controlSize(.small)
            .disabled(store.busy)
        } form: {
            if page.addFor == "commandcode", page.editTarget == nil {
                commandCodeAddForm
            } else if let target = page.editTarget,
                      let account = store.accounts.first(where: { $0.name == target }),
                      account.provider == "commandcode" {
                editForm(account)
            }
        } body: {
            if rows.isEmpty {
                EmptyState(symbol: "key.fill",
                           title: "No Command Code accounts",
                           message: "Add an account with its API key — every enabled account joins the shared pool, drained one at a time.") {
                    Button("Add Command Code account") { page.toggleAdd("commandcode") }
                }
            } else {
                DataTable(columns: commandCodeColumns(rows), rowCount: rows.count, state: page.ccTable,
                          maxHeight: 56 + CGFloat(rows.count) * 30 + 8)
            }
        }
    }

    private func commandCodeColumns(_ rows: [AccountView]) -> [DataColumn] {
        var columns = [
            DataColumn(title: "Account", width: 230, compare: columnByText { rows[$0].name }) { row in
                AnyView(Text(rows[row].name).font(.system(size: 11)).lineLimit(1))
            },
        ]
        for period in UsagePeriod.allCases {
            let content: (Int) -> QuotaCellContent = { row in
                guard let limits = store.limitsByName(rows[row].name) else { return .dash }
                return AccountQuota.commandCodeCell(limits, period: period, first: period == .fiveHour)
            }
            columns.append(DataColumn(title: period.header, width: 118, alignsRight: true) { row in
                quotaCell(content(row))
            })
        }
        columns.append(DataColumn(title: "Enabled", width: 74) { row in
            AnyView(enabledToggle(rows[row]))
        })
        columns.append(DataColumn(title: "Actions", width: 78) { row in
            AnyView(HStack(spacing: 8) {
                iconButton("pencil", help: "Edit \(rows[row].name)") { page.beginEdit(rows[row].name) }
                iconButton("trash", help: "Remove \(rows[row].name)", tint: .red) {
                    Task { await store.removeAccount(rows[row].name) }
                }
            })
        })
        return columns
    }

    private var commandCodeAddForm: some View {
        if page.addTurnstile == nil { page.addTurnstile = TurnstileController() }
        let usesToken = !page.addToken.trimmingCharacters(in: .whitespaces).isEmpty
        let captcha = page.addCaptcha
        let canSubmit = !store.busy
            && !page.addEmail.trimmingCharacters(in: .whitespaces).isEmpty
            && (usesToken || !page.addKey.trimmingCharacters(in: .whitespaces).isEmpty)
            && (usesToken || (!page.addPassword.isEmpty && !captcha.isEmpty))
        return AccountFormBox {
            field("API key", text: $page.addKey, secure: true, placeholder: "user_…")
            field("Command Code email", text: $page.addEmail, placeholder: "you@example.com")
            field("Command Code password", text: $page.addPassword, secure: true)
            Toggle("Use a session token instead", isOn: $page.useTokenPath)
                .toggleStyle(.checkbox)
                .controlSize(.small)
            if page.useTokenPath {
                field("Session token", text: $page.addToken, secure: true)
            }
            Text("Complete Command Code verification before signing in. Password is stored in accounts.json for session renewal.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if !usesToken, let controller = page.addTurnstile {
                TurnstileWebView(controller: controller).frame(height: 88)
            }
            HStack(spacing: 10) {
                Button("Add account") { submitAddCC() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                    .disabled(!canSubmit)
                Button("Cancel") { page.cancelForms() }
                    .controlSize(.small)
            }
        }
    }

    private func editForm(_ account: AccountView) -> some View {
        if page.editTurnstile == nil { page.editTurnstile = TurnstileController() }
        let emailChanged = page.editEmail.trimmingCharacters(in: .whitespaces) != (account.email ?? "")
        let captcha = page.editCaptcha
        let needsCaptcha = account.provider == "commandcode" && emailChanged
        let canSave = !store.busy && !(needsCaptcha && captcha.isEmpty)
        return AccountFormBox {
            field("API key", text: $page.editKey, secure: true,
                  placeholder: account.hasKey == true ? "Saved API key (leave blank to keep)" : "user_…")
            field("Command Code email", text: $page.editEmail)
            field("Command Code password", text: $page.editPassword, secure: true,
                  placeholder: account.hasPassword == true ? "Saved password (leave blank to keep)" : "")
            if account.provider != "commandcode" {
                field("Session token", text: $page.editToken, secure: true)
            }
            Text("Complete Command Code verification before signing in or updating the email.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if showsTurnstile(password: page.editPassword, emailChanged: emailChanged),
               let controller = page.editTurnstile {
                TurnstileWebView(controller: controller).frame(height: 88)
            }
            HStack(spacing: 10) {
                Button("Save") { submitEdit(account) }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                    .disabled(!canSave)
                Button("Cancel") { page.cancelForms() }
                    .controlSize(.small)
            }
        }
    }

    private func showsTurnstile(password: String, emailChanged: Bool) -> Bool {
        !(password.isEmpty && !emailChanged)
    }

    private var workbuddySection: some View {
        let rows = store.workbuddyAccounts
        return sectionCard("WorkBuddy", count: rows.count) {
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await store.refreshWorkbuddy() }
            }
            .controlSize(.small)
            .disabled(store.busy || rows.isEmpty)
            Button(page.addFor == "workbuddy" ? "Close" : "Add",
                   systemImage: page.addFor == "workbuddy" ? "xmark" : "plus") {
                page.toggleAdd("workbuddy")
            }
            .controlSize(.small)
            .disabled(store.busy)
        } form: {
            if page.addFor == "workbuddy" {
                workbuddyAddForm
            }
        } body: {
            if rows.isEmpty {
                EmptyState(symbol: "cpu",
                           title: "No WorkBuddy accounts",
                           message: "Sign in with the browser flow, read the credential the CodeBuddy desktop app wrote on this machine, or paste the auth JSON.") {
                    Button("Add WorkBuddy account") { page.toggleAdd("workbuddy") }
                }
            } else {
                DataTable(columns: workbuddyColumns(rows), rowCount: rows.count, state: page.wbTable,
                          maxHeight: 56 + CGFloat(rows.count) * 30 + 8)
            }
        }
    }

    private func workbuddyColumns(_ rows: [AccountView]) -> [DataColumn] {
        [
            DataColumn(title: "Account", width: 200) { row in
                AnyView(Text(rows[row].workbuddyNickname ?? "—").font(.system(size: 11)))
            },
            DataColumn(title: "UID", width: 160) { row in
                AnyView(Text(rows[row].workbuddyUid ?? "—")
                    .font(RavenFont.mono(11))
                    .lineLimit(1)
                    .help(rows[row].workbuddyUid ?? ""))
            },
            DataColumn(title: "Credits", width: 110, alignsRight: true) { row in
                let status = store.wbStatusByUid(rows[row].workbuddyUid)
                guard let status else { return AnyView(Text("—").font(RavenFont.numeric(11))) }
                if status.cooling {
                    return AnyView(BadgeText(text: wbCoolingText(status), tint: .secondary, soft: true)
                        .help(status.reason ?? ""))
                }
                return AnyView(Text(AccountQuota.creditsText(status.credits)).font(RavenFont.numeric(11)))
            },
            DataColumn(title: "Enabled", width: 74) { row in
                AnyView(enabledToggle(rows[row]))
            },
            DataColumn(title: "Actions", width: 56) { row in
                AnyView(iconButton("trash", help: "Remove \(rows[row].name)", tint: .red) {
                    Task { await store.removeAccount(rows[row].name) }
                })
            },
        ]
    }

    private func wbCoolingText(_ status: WorkbuddyAccountStatus) -> String {
        guard let left = status.coolRemainingSec, left > 0 else { return "cooling" }
        return "cooling · \(left / 60):\(String(format: "%02d", left % 60))"
    }

    private var workbuddyAddForm: some View {
        let canSubmit = !store.busy && !page.wbAuthJson.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return AccountFormBox {
            HStack {
                Text("Auth JSON (or sign in)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Read from local") { readWorkbuddyLocal() }
                    .controlSize(.small)
                    .disabled(store.busy)
            }
            TextEditor(text: $page.wbAuthJson)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 96)
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 1) }
            if !page.wbNote.isEmpty {
                Text(page.wbNote).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button("Add WorkBuddy") { submitAddWorkbuddy() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                    .disabled(!canSubmit)
                Button("Sign in") {
                    page.cancelForms()
                    Task { await store.startWorkbuddyOAuth() }
                }
                .controlSize(.small)
                .disabled(store.busy || store.wbOAuth != nil)
                Button("Cancel") { page.cancelForms() }
                    .controlSize(.small)
            }
        }
    }

    private var antigravitySection: some View {
        let rows = store.antigravityAccounts
        return sectionCard("Antigravity", count: rows.count) {
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await store.refreshAntigravity() }
            }
            .controlSize(.small)
            .disabled(store.busy || rows.isEmpty)
            Button(page.addFor == "antigravity" ? "Close" : "Add",
                   systemImage: page.addFor == "antigravity" ? "xmark" : "plus") {
                page.toggleAdd("antigravity")
            }
            .controlSize(.small)
            .disabled(store.busy)
        } form: {
            if page.addFor == "antigravity" {
                antigravityAddForm
            }
        } body: {
            if rows.isEmpty {
                EmptyState(symbol: "sparkles",
                           title: "No Antigravity accounts",
                           message: "Sign in with Google to reach the Gemini, Claude and GPT-OSS models Antigravity advertises for your account.") {
                    Button("Add Antigravity account") { page.toggleAdd("antigravity") }
                }
            } else {
                DataTable(columns: antigravityColumns(rows), rowCount: rows.count, state: page.agTable,
                          maxHeight: 56 + CGFloat(rows.count) * 30 + 8)
            }
        }
    }

    private func antigravityColumns(_ rows: [AccountView]) -> [DataColumn] {
        var columns = [
            DataColumn(title: "Account", width: 150) { row in
                if store.agExpired(rows[row].name) {
                    return AnyView(HStack(spacing: 4) {
                        Text(rows[row].name).font(.system(size: 12))
                        BadgeText(text: "refreshing", tint: .secondary, soft: true)
                    })
                }
                return AnyView(Text(rows[row].name).font(.system(size: 11)).lineLimit(1))
            },
            DataColumn(title: "Google account", width: 170) { row in
                AnyView(Text(rows[row].antigravityEmail ?? "—")
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .help(rows[row].antigravityEmail ?? ""))
            },
        ]
        let quota = store.agQuota
        let names = rows.map(\.name)
        let quotaColumns = AccountQuota.antigravityQuotaColumns(quota)
        let firstKey = quotaColumns.first?.key
        for column in quotaColumns {
            let content: (Int) -> QuotaCellContent = { row in
                AccountQuota.antigravityCell(quota: quota.first { $0.name == names[row] },
                                             column: column,
                                             first: column.key == firstKey)
            }
            columns.append(DataColumn(title: column.header, width: 108, alignsRight: true) { row in
                quotaCell(content(row), help: column.header)
            })
        }
        columns.append(DataColumn(title: "Enabled", width: 74) { row in
            AnyView(enabledToggle(rows[row]))
        })
        columns.append(DataColumn(title: "Actions", width: 56) { row in
            AnyView(iconButton("trash", help: "Remove \(rows[row].name)", tint: .red) {
                Task { await store.removeAccount(rows[row].name) }
            })
        })
        return columns
    }

    private var antigravityAddForm: some View {
        let canUseCallback = !store.busy && store.agOAuth != nil
            && !page.agCallback.trimmingCharacters(in: .whitespaces).isEmpty
        return AccountFormBox {
            Text("Sign in opens Google in a new tab and catches the redirect on localhost:51121. On a machine without a browser, open the link yourself and paste the whole callback URL back here.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            field("Callback URL (optional)", text: $page.agCallback,
                  placeholder: "http://localhost:51121/oauth-callback?state=…&code=…", mono: true)
            HStack(spacing: 10) {
                Button(store.agOAuth == nil ? "Sign in with Google" : "Restart sign-in",
                       systemImage: "sparkles") {
                    Task { await store.startAntigravityOAuth() }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                .disabled(store.busy)
                Button("Use pasted callback") { submitAntigravityCallback() }
                    .controlSize(.small)
                    .disabled(!canUseCallback)
                Button("Cancel") { page.cancelForms() }
                    .controlSize(.small)
            }
        }
    }

    private func quotaCell(_ content: QuotaCellContent, help: String? = nil) -> AnyView {
        switch content {
        case .dash:
            return AnyView(Text("—").font(RavenFont.numeric(11)).foregroundStyle(.secondary))
        case .badge(let text, let tip):
            return AnyView(BadgeText(text: text, tint: .secondary, soft: true).help(tip ?? ""))
        case .value(let percent, let reset, let title, let fraction):
            return AnyView(QuotaValue(percent: percent, reset: reset, fraction: fraction)
                .help(title ?? help ?? ""))
        }
    }

    private func enabledToggle(_ account: AccountView) -> some View {
        Toggle("", isOn: Binding(
            get: { !(account.disabled ?? false) },
            set: { on in Task { await store.setEnabled(account, enabled: on) } }))
        .toggleStyle(.switch)
        .controlSize(.mini)
        .labelsHidden()
        .disabled(store.busy)
    }

    private func iconButton(_ symbol: String, help: String,
                            tint: Color = .secondary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .frame(width: Metrics.minHitTarget, height: Metrics.minHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .disabled(store.busy)
    }

    private func field(_ title: String, text: Binding<String>, secure: Bool = false,
                       placeholder: String = "", mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Group {
                if secure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .font(mono ? .system(size: 11, design: .monospaced) : .system(size: 11))
        }
    }

    private func submitAddCC() {
        let email = page.addEmail.trimmingCharacters(in: .whitespaces)
        Task {
            let ok = await store.signInCommandCode(name: email,
                                                   key: page.addKey.trimmingCharacters(in: .whitespaces),
                                                   email: email,
                                                   password: page.addPassword,
                                                   sessionToken: page.addToken.trimmingCharacters(in: .whitespaces),
                                                   captcha: page.addCaptcha)
            if ok { page.cancelForms() }
        }
    }

    private func submitEdit(_ account: AccountView) {
        let email = page.editEmail.trimmingCharacters(in: .whitespaces)
        let password = page.editPassword
        let token = page.editToken.trimmingCharacters(in: .whitespaces)
        let captcha = page.editCaptcha
        let emailChanged = email != (account.email ?? "")
        let wantsSignIn = account.provider == "commandcode"
            && (!password.isEmpty || !token.isEmpty || (emailChanged && !captcha.isEmpty))
        Task {
            let ok: Bool
            if wantsSignIn {
                ok = await store.signInCommandCode(name: account.name, key: nil, email: email,
                                                   password: password, sessionToken: token,
                                                   captcha: captcha)
            } else {
                ok = await store.editAccount(name: account.name,
                                             key: page.editKey.trimmingCharacters(in: .whitespaces),
                                             sessionToken: token, email: nil, password: password,
                                             disabled: nil)
            }
            if ok { page.cancelForms() }
        }
    }

    private func submitAddWorkbuddy() {
        let auth = page.wbAuthJson.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !auth.isEmpty else { return }
        Task {
            if await store.addWorkbuddy(authJson: auth) { page.cancelForms() }
        }
    }

    private func readWorkbuddyLocal() {
        page.wbNote = ""
        Task {
            guard let result = await store.readWorkbuddyLocal() else { return }
            if result.found, let json = result.authJson, !json.isEmpty {
                page.wbAuthJson = json
                let who = result.nickname ?? result.uid ?? "account"
                let source = result.source.map { " from \($0)" } ?? ""
                page.wbNote = "Loaded \(who)\(source)"
            }
        }
    }

    private func submitAntigravityCallback() {
        guard let session = store.agOAuth?.session else { return }
        let callback = page.agCallback.trimmingCharacters(in: .whitespaces)
        guard !callback.isEmpty else { return }
        Task {
            if await store.completeAntigravity(session: session, callback: callback) {
                page.cancelForms()
            }
        }
    }
}

struct AccountFormBox<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(Metrics.spacing3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 1) }
    }
}
