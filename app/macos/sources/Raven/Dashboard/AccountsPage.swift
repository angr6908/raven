import AppKit
import SwiftUI

struct AccountsPage: View {
    private let store = AccountsStore.shared
    @State private var removing: AccountView?

    var body: some View {
        Form {
            if store.error != nil || store.fetchError != nil || store.agOAuth != nil || store.wbOAuth != nil {
                Section {
                    Notice(message: store.error ?? store.fetchError)
                    if let oauth = store.agOAuth {
                        WaitingBanner(text: "Waiting for the Google sign-in. Finish it in your browser.", url: oauth.url)
                    }
                    if let oauth = store.wbOAuth {
                        WaitingBanner(text: "Waiting for sign-in. Complete the login in your browser.", url: oauth.url)
                    }
                }
            }
            AccountSection(kind: .workbuddy, accounts: store.workbuddyAccounts, removing: $removing)
            AccountSection(kind: .antigravity, accounts: store.antigravityAccounts, removing: $removing)
        }
        .formStyle(.grouped)
        .navigationTitle("Accounts")
        .confirmationDialog("Remove this account?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { account in
            Button("Remove \(account.name)", role: .destructive) {
                Task { await store.removeAccount(account.name) }
            }
        } message: { _ in
            Text("The proxy stops routing requests through this account.")
        }
        .onAppear { store.start() }
        .onDisappear { store.stop() }
    }
}

private struct WaitingBanner: View {
    let text: String
    let url: String

    var body: some View {
        HStack(spacing: Space.md) {
            ProgressView().controlSize(.small)
            Text(text)
            Spacer()
            Button("Open Sign-In") {
                if let link = URL(string: url) { NSWorkspace.shared.open(link) }
            }
            .buttonStyle(.bordered)
        }
    }
}

private struct AccountSection: View {
    private let store = AccountsStore.shared
    @Environment(AppModel.self) private var app
    let kind: AccountKind
    let accounts: [AccountView]
    @Binding var removing: AccountView?

    var body: some View {
        Section(kind.title) {
            ForEach(accounts) { account in
                if kind == .workbuddy {
                    WorkbuddyRow(account: account, removing: $removing)
                } else {
                    AntigravityRow(account: account, removing: $removing)
                }
            }
            HStack(spacing: Space.sm) {
                Text(summary).foregroundStyle(.secondary)
                Spacer(minLength: Space.md)
                Button("Refresh") {
                    Task {
                        if kind == .workbuddy { await store.refreshWorkbuddy() } else { await store.refreshAntigravity() }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(store.busy || accounts.isEmpty)
                Button("Add…") { app.sheet = .addAccount(kind) }
                    .buttonStyle(.bordered)
                    .disabled(store.busy)
            }
        }
    }

    private var summary: String {
        if accounts.isEmpty { return "No accounts" }
        return subtitle ?? (accounts.count == 1 ? "1 account" : "\(accounts.count) accounts")
    }

    private var subtitle: String? {
        switch kind {
        case .workbuddy:
            guard let status = store.wbStatus else { return nil }
            return "\(status.healthy) healthy · \(status.cooling) cooling · \(status.disabled) disabled"
        case .antigravity:
            guard let status = store.agStatus else { return nil }
            return "\(status.healthy) of \(status.total) healthy"
        }
    }
}

private struct RowActions: View {
    private let store = AccountsStore.shared
    let account: AccountView
    @Binding var removing: AccountView?

    var body: some View {
        HStack(spacing: Space.md) {
            Toggle("Enabled", isOn: Binding(
                get: { !(account.disabled ?? false) },
                set: { on in Task { await store.setEnabled(account, enabled: on) } }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(store.busy)
                .help(account.disabled == true ? "Enable this account" : "Disable this account")
            Button(role: .destructive) {
                removing = account
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove \(account.name)")
        }
    }
}

private struct WorkbuddyRow: View {
    private let store = AccountsStore.shared
    let account: AccountView
    @Binding var removing: AccountView?

    var body: some View {
        let status = store.workbuddyStatus(for: account)
        HStack(spacing: Space.md) {
            AccountAvatar()
            VStack(alignment: .leading, spacing: 2) {
                Text(account.workbuddyNickname ?? account.name).font(.body.weight(.medium))
                Text(account.workbuddyUid ?? account.name)
                    .font(.identifierSmall)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            Spacer(minLength: Space.md)
            if let status {
                if status.cooling {
                    Badge(text: coolingText(status), tint: .orange, symbol: "snowflake")
                        .help(status.reason ?? "Cooling down")
                } else {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(AccountQuota.creditsText(status.credits)).font(.callout.monospacedDigit().weight(.semibold))
                        Text("credits").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            RowActions(account: account, removing: $removing)
        }
        .opacity(account.disabled == true ? 0.55 : 1)
    }

    private func coolingText(_ status: WorkbuddyAccountStatus) -> String {
        guard let left = status.coolRemainingSec, left > 0 else { return "Cooling" }
        return "Cooling · \(left / 60):\(String(format: "%02d", left % 60))"
    }
}

private struct AntigravityRow: View {
    private let store = AccountsStore.shared
    let account: AccountView
    @Binding var removing: AccountView?

    var body: some View {
        let quota = store.agQuotaByName(account.name)
        let columns = AccountQuota.antigravityQuotaColumns(store.agQuota)
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.md) {
                AccountAvatar()
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Space.xs) {
                        Text(account.name).font(.body.weight(.medium))
                        if store.agExpired(account.name) {
                            Badge(text: "Refreshing token", tint: .secondary)
                        }
                    }
                    Text(account.antigravityEmail ?? "—")
                        .font(.identifierSmall)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer(minLength: Space.md)
                RowActions(account: account, removing: $removing)
            }
            if let error = quota?.error, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if !columns.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: Space.md, alignment: .top)],
                          alignment: .leading, spacing: Space.sm) {
                    ForEach(Array(columns.enumerated()), id: \.element.key) { index, column in
                        let content = AccountQuota.antigravityCell(quota: quota, column: column, first: index == 0)
                        if case .value(let percent, let reset, _, let fraction) = content {
                            QuotaGauge(title: column.header, percent: percent, reset: reset, fraction: fraction)
                        }
                    }
                }
            }
        }
        .opacity(account.disabled == true ? 0.55 : 1)
    }
}

private struct QuotaGauge: View {
    let title: String
    let percent: String
    let reset: String?
    let fraction: Double?

    var body: some View {
        let value = max(0, min(1, fraction ?? 0))
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Text(percent).font(.subheadline.monospacedDigit().weight(.semibold))
            }
            Gauge(value: value) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(Palette.remaining(value))
            if let reset {
                Label("resets in \(reset)", systemImage: "clock")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct AccountAvatar: View {
    var body: some View {
        Image(systemName: "person.crop.circle.fill")
            .font(.system(size: 28))
            .foregroundStyle(.tertiary)
            .frame(width: 32, height: 32)
    }
}
