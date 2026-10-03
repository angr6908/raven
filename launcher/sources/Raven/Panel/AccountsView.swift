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
            PanelPageHeader(title: "Accounts",
                            subtitle: subtitle,
                            icon: "person.badge.key.fill")
            PanelNotice(message: store.error ?? store.fetchError)
            waitingBanners
            WorkbuddySection(store: store, page: page)
            AntigravitySection(store: store, page: page)
        }
        .onAppear { store.start() }
        .onDisappear { store.stop() }
    }

    private var subtitle: String? {
        let wb = store.workbuddyAccounts.count
        let ag = store.antigravityAccounts.count
        if wb == 0 && ag == 0 { return nil }
        let parts: [String] = [
            wb == 0 ? nil : "\(wb) WorkBuddy",
            ag == 0 ? nil : "\(ag) Antigravity",
        ].compactMap { $0 }
        return parts.joined(separator: " · ")
    }
    private var waitingBanners: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let oauth = store.agOAuth {
                AccountsWaitingBanner(text: "Waiting for the Google sign-in — finish it at accounts.google.com.",
                                      url: oauth.url)
            }
            if let oauth = store.wbOAuth {
                AccountsWaitingBanner(text: "Waiting for sign-in — complete the login at \(oauth.url).",
                                      url: oauth.url)
            }
        }
    }
}

struct AccountsWaitingBanner: View {
    var text: String
    var url: String

    var body: some View {
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
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1)
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
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 1)
        }
    }
}

struct WorkbuddySection: View {
    let store: AccountsStore
    @Bindable var page: AccountsPageState

    var body: some View {
        PanelSection(title: "WorkBuddy", trailing: AnyView(sectionActions)) {
            sectionCard
        }
    }

    var sectionActions: some View {
        let rows = store.workbuddyAccounts
        return HStack(spacing: 8) {
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
        }
    }

    var sectionCard: some View {
        let rows = store.workbuddyAccounts
        return GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                if page.addFor == "workbuddy" {
                    WorkbuddyAddForm(store: store, page: page)
                }
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
    }

    private func workbuddyColumns(_ rows: [AccountView]) -> [DataColumn] {
        [
            DataColumn(title: "Account", width: 200) { row in
                AnyView(AccountCell(name: rows[row].workbuddyNickname ?? "—"))
            },
            DataColumn(title: "UID", width: 160) { row in
                AnyView(MonoCell(text: rows[row].workbuddyUid ?? "—"))
            },
            DataColumn(title: "Credits", width: 110, alignsRight: true) { row in
                AnyView(CreditsCell(store: store, uid: rows[row].workbuddyUid))
            },
            DataColumn(title: "Enabled", width: 74) { row in
                AnyView(AccountEnabledToggle(store: store, account: rows[row]))
            },
            DataColumn(title: "Actions", width: 56) { row in
                AnyView(AccountActionButton(symbol: "trash",
                                            help: "Remove \(rows[row].name)",
                                            tint: .red,
                                            busy: store.busy) {
                    Task { await store.removeAccount(rows[row].name) }
                })
            },
        ]
    }
}

struct WorkbuddyAddForm: View {
    let store: AccountsStore
    @Bindable var page: AccountsPageState

    var body: some View {
        let canSubmit = !store.busy && !page.wbAuthJson.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        AccountFormBox {
            HStack {
                Text("Auth JSON (or sign in)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Read from local") { readLocal() }
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
                Button("Add WorkBuddy") { submit() }
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

    private func readLocal() {
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

    private func submit() {
        let auth = page.wbAuthJson.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !auth.isEmpty else { return }
        Task {
            if await store.addWorkbuddy(authJson: auth) { page.cancelForms() }
        }
    }
}

struct AntigravitySection: View {
    let store: AccountsStore
    @Bindable var page: AccountsPageState

    var body: some View {
        PanelSection(title: "Antigravity", trailing: AnyView(sectionActions)) {
            sectionCard
        }
    }

    var sectionActions: some View {
        let rows = store.antigravityAccounts
        return HStack(spacing: 8) {
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
        }
    }

    var sectionCard: some View {
        let rows = store.antigravityAccounts
        return GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                if page.addFor == "antigravity" {
                    AntigravityAddForm(store: store, page: page)
                }
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
    }

    private func antigravityColumns(_ rows: [AccountView]) -> [DataColumn] {
        var columns = [
            DataColumn(title: "Account", width: 150) { row in
                AnyView(AntigravityAccountCell(store: store, account: rows[row]))
            },
            DataColumn(title: "Google account", width: 170) { row in
                AnyView(MonoCell(text: rows[row].antigravityEmail ?? "—"))
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
                AnyView(QuotaCellView(content: content(row), help: column.header))
            })
        }
        columns.append(DataColumn(title: "Enabled", width: 74) { row in
            AnyView(AccountEnabledToggle(store: store, account: rows[row]))
        })
        columns.append(DataColumn(title: "Actions", width: 56) { row in
            AnyView(AccountActionButton(symbol: "trash",
                                        help: "Remove \(rows[row].name)",
                                        tint: .red,
                                        busy: store.busy) {
                Task { await store.removeAccount(rows[row].name) }
            })
        })
        return columns
    }
}

struct AntigravityAddForm: View {
    let store: AccountsStore
    @Bindable var page: AccountsPageState

    var body: some View {
        let canUseCallback = !store.busy && store.agOAuth != nil
            && !page.agCallback.trimmingCharacters(in: .whitespaces).isEmpty
        AccountFormBox {
            Text("Sign in opens Google in a new tab and catches the redirect on localhost:51121. On a machine without a browser, open the link yourself and paste the whole callback URL back here.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            MonoField(title: "Callback URL (optional)",
                      text: $page.agCallback,
                      placeholder: "http://localhost:51121/oauth-callback?state=…&code=…")
            HStack(spacing: 10) {
                Button(store.agOAuth == nil ? "Sign in with Google" : "Restart sign-in",
                       systemImage: "sparkles") {
                    Task { await store.startAntigravityOAuth() }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                .disabled(store.busy)
                Button("Use pasted callback") { submit() }
                    .controlSize(.small)
                    .disabled(!canUseCallback)
                Button("Cancel") { page.cancelForms() }
                    .controlSize(.small)
            }
        }
    }

    private func submit() {
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

struct AccountCell: View {
    let name: String

    var body: some View {
        Text(name).font(.system(size: 11))
    }
}

struct MonoCell: View {
    let text: String

    var body: some View {
        Text(text)
            .font(RavenFont.mono(11))
            .lineLimit(1)
            .help(text)
    }
}

struct CreditsCell: View {
    let store: AccountsStore
    let uid: String?

    var body: some View {
        let status = uid.flatMap { store.wbStatusByUid($0) }
        if let status {
            if status.cooling {
                BadgeText(text: coolingText(status), tint: .secondary, soft: true)
                    .help(status.reason ?? "")
            } else {
                Text(AccountQuota.creditsText(status.credits))
                    .font(RavenFont.numeric(11))
            }
        } else {
            Text("—").font(RavenFont.numeric(11))
        }
    }

    private func coolingText(_ status: WorkbuddyAccountStatus) -> String {
        guard let left = status.coolRemainingSec, left > 0 else { return "cooling" }
        return "cooling · \(left / 60):\(String(format: "%02d", left % 60))"
    }
}

struct AntigravityAccountCell: View {
    let store: AccountsStore
    let account: AccountView

    var body: some View {
        if store.agExpired(account.name) {
            HStack(spacing: 4) {
                Text(account.name).font(.system(size: 12))
                BadgeText(text: "refreshing", tint: .secondary, soft: true)
            }
        } else {
            Text(account.name).font(.system(size: 11)).lineLimit(1)
        }
    }
}

struct QuotaCellView: View {
    let content: QuotaCellContent
    var help: String?

    var body: some View {
        switch content {
        case .dash:
            Text("—").font(RavenFont.numeric(11)).foregroundStyle(.secondary)
        case .badge(let text, let tip):
            BadgeText(text: text, tint: .secondary, soft: true).help(tip ?? "")
        case .value(let percent, let reset, let title, let fraction):
            QuotaValue(percent: percent, reset: reset, fraction: fraction)
                .help(title ?? help ?? "")
        }
    }
}

struct AccountEnabledToggle: View {
    let store: AccountsStore
    let account: AccountView

    var body: some View {
        Toggle("", isOn: Binding(
            get: { !(account.disabled ?? false) },
            set: { on in Task { await store.setEnabled(account, enabled: on) } }))
        .toggleStyle(.switch)
        .controlSize(.mini)
        .labelsHidden()
        .disabled(store.busy)
    }
}

struct AccountActionButton: View {
    let symbol: String
    let help: String
    var tint: Color = .secondary
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .frame(width: Metrics.minHitTarget, height: Metrics.minHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .disabled(busy)
    }
}

struct MonoField: View {
    let title: String
    @Binding var text: String
    var placeholder: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(.system(size: 11, design: .monospaced))
        }
    }
}
