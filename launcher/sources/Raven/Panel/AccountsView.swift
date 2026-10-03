import AppKit
import SwiftUI

private let accountsPageState = AccountsPageState()

@Observable
final class AccountsPageState {
    var addFor: String?

    var wbAuthJson = ""
    var wbNote = ""
    var agCallback = ""

    var wbTable = DataTableState()
    var agTable = DataTableState()

    func toggleAdd(_ provider: String) {
        if addFor == provider {
            addFor = nil
        } else {
            addFor = provider
        }
        resetForms()
    }

    func cancelForms() {
        addFor = nil
        resetForms()
    }

    private func resetForms() {
        wbAuthJson = ""
        wbNote = ""
        agCallback = ""
    }
}

struct AccountsView: View {
    private let store = AccountsStore.shared
    @Bindable private var page = accountsPageState

    var body: some View {
        PanelPage {
            PanelNotice(message: store.error ?? store.fetchError)
            banners
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
