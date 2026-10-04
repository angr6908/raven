import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AccountsStore {
    static let shared = AccountsStore()

    static var cacheDirectoryOverride: URL?

    private(set) var accounts: [AccountView] = []
    private(set) var wbStatus: WorkbuddyStatusResponse?
    private(set) var agStatus: AntigravityStatusResponse?
    private(set) var agQuota: [QuotaAccount] = []
    private(set) var error: String?
    private(set) var fetchError: String?
    private(set) var busy = false
    private(set) var quotaWasStale = false

    struct OAuthSession: Equatable {
        var session: String
        var url: String
    }
    var wbOAuth: OAuthSession?
    var agOAuth: OAuthSession?

    var workbuddyAccounts: [AccountView] { accounts.filter { $0.provider == "workbuddy" } }
    var antigravityAccounts: [AccountView] { accounts.filter { $0.provider == "antigravity" } }

    private var pollTask: Task<Void, Never>?
    private var started = false

    private static var quotaCacheURL: URL {
        (cacheDirectoryOverride ?? ProviderStore.configDirectory)
            .appending(path: "panel-quota-cache.json")
    }

    init() {
        if let data = PanelCache.loadQuota(Self.quotaCacheURL) {
            if let cached = try? PanelJSON.decoder.decode(QuotaResponse.self, from: data) {
                agQuota = cached.accounts
            } else {
                quotaWasStale = true
                PanelCache.quarantine(Self.quotaCacheURL)
            }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        Task { await self.refresh() }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    func stop() {
        started = false
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        do {
            let list: AccountListResponse = try await PanelClient.shared.get("/api/accounts")
            accounts = list.accounts
            fetchError = nil
        } catch {
            fetchError = (error as? PanelError)?.noticeText ?? error.localizedDescription
        }
        if accounts.contains(where: { $0.provider == "workbuddy" }) {
            if let status: WorkbuddyStatusResponse = try? await PanelClient.shared.get("/api/workbuddy/status") {
                wbStatus = status
            }
        }
        if accounts.contains(where: { $0.provider == "antigravity" }) {
            if let status: AntigravityStatusResponse = try? await PanelClient.shared.get("/api/antigravity/status") {
                agStatus = status
            }
            if let quota: QuotaResponse = try? await PanelClient.shared.get("/api/antigravity/quota") {
                agQuota = quota.accounts
                if let data = try? PanelJSON.encoder.encode(quota) {
                    PanelCache.saveQuota(data, to: Self.quotaCacheURL)
                }
            }
        }
    }


    func workbuddyStatus(for account: AccountView) -> WorkbuddyAccountStatus? {
        guard let accounts = wbStatus?.accounts else { return nil }
        return WorkbuddyKeying.status(in: accounts, for: account)
    }

    func agQuotaByName(_ name: String) -> QuotaAccount? {
        agQuota.first { $0.name == name }
    }

    func agExpired(_ name: String) -> Bool {
        agStatus?.accounts.first { $0.name == name }?.expired ?? false
    }

    @discardableResult
    func run(_ action: () async throws -> Void, fallback: String) async -> Bool {
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await action()
            await refresh()
            return true
        } catch {
            let message = (error as? PanelError)?.noticeText ?? error.localizedDescription
            self.error = message.isEmpty ? fallback : message
            return false
        }
    }

    func removeAccount(_ name: String) async -> Bool {
        await run({
            try await PanelClient.shared.delete("/api/accounts",
                                                query: [URLQueryItem(name: "name", value: name)])
        }, fallback: "Failed to remove account")
    }

    func setEnabled(_ account: AccountView, enabled: Bool) async -> Bool {
        await run({
            try await PanelClient.shared.postVoid("/api/accounts/edit",
                                                  json: EditAccountBody(name: account.name, disabled: !enabled))
        }, fallback: "Failed to update account")
    }

    func addWorkbuddy(authJson: String) async -> Bool {
        await run({
            try await PanelClient.shared.postVoid("/api/accounts/workbuddy",
                                                  json: WorkbuddyAddBody(authJson: authJson))
        }, fallback: "Failed to add WorkBuddy account")
    }

    func readWorkbuddyLocal() async -> WorkbuddyLocalResponse? {
        busy = true
        error = nil
        defer { busy = false }
        do {
            let result: WorkbuddyLocalResponse = try await PanelClient.shared.get("/api/accounts/workbuddy/local")
            if !result.found || result.authJson?.isEmpty != false {
                let searched = result.searched ?? []
                error = "No local WorkBuddy credential found."
                    + (searched.isEmpty ? "" : " Looked in: \(searched.joined(separator: ", "))")
                    + " Sign in with the CodeBuddy desktop app first, or paste the JSON."
            }
            return result
        } catch {
            self.error = (error as? PanelError)?.noticeText ?? error.localizedDescription
            return nil
        }
    }

    func refreshWorkbuddy() async {
        await run({
            let status: WorkbuddyStatusResponse = try await PanelClient.shared.post("/api/workbuddy/refresh", json: EmptyBody())
            self.wbStatus = status
        }, fallback: "Failed to refresh WorkBuddy")
    }

    func refreshAntigravity() async {
        await run({
            let status: AntigravityStatusResponse = try await PanelClient.shared.post("/api/antigravity/refresh", json: EmptyBody())
            self.agStatus = status
        }, fallback: "Failed to refresh Antigravity")
    }

    func startWorkbuddyOAuth() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            let start: OAuthStartResponse = try await PanelClient.shared.get("/api/oauth/workbuddy/start")
            NSWorkspace.shared.open(URL(string: start.url) ?? URL(string: "about:blank")!)
            wbOAuth = OAuthSession(session: start.session, url: start.url)
            pollWorkbuddy()
        } catch {
            self.error = (error as? PanelError)?.noticeText ?? error.localizedDescription
        }
    }

    func startAntigravityOAuth() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            let start: OAuthStartResponse = try await PanelClient.shared.get("/api/oauth/antigravity/start")
            NSWorkspace.shared.open(URL(string: start.url) ?? URL(string: "about:blank")!)
            agOAuth = OAuthSession(session: start.session, url: start.url)
            pollAntigravity()
        } catch {
            self.error = (error as? PanelError)?.noticeText ?? error.localizedDescription
        }
    }

    func completeAntigravity(session: String, callback: String) async -> Bool {
        await run({
            try await PanelClient.shared.postVoid("/api/accounts/antigravity",
                                                  json: AntigravityAddBody(session: session, callback: callback))
            self.agOAuth = nil
        }, fallback: "Failed to finish the Antigravity sign-in")
    }

    private func pollWorkbuddy() {
        guard let session = wbOAuth?.session else { return }
        Task { @MainActor [weak self] in
            while !Task.isCancelled, self?.wbOAuth?.session == session {
                try? await Task.sleep(for: .seconds(3))
                guard let self, self.wbOAuth?.session == session, !Task.isCancelled else { return }
                let status: OAuthStatusResponse? = try? await PanelClient.shared.get(
                    "/api/oauth/workbuddy/status",
                    query: [URLQueryItem(name: "session", value: session)])
                guard let status, status.done else { continue }
                self.wbOAuth = nil
                if status.success {
                    await self.refresh()
                } else {
                    self.error = status.error ?? "WorkBuddy sign-in failed"
                }
                return
            }
        }
    }

    private func pollAntigravity() {
        guard let session = agOAuth?.session else { return }
        Task { @MainActor [weak self] in
            while !Task.isCancelled, self?.agOAuth?.session == session {
                try? await Task.sleep(for: .seconds(3))
                guard let self, self.agOAuth?.session == session, !Task.isCancelled else { return }
                let status: OAuthStatusResponse? = try? await PanelClient.shared.get(
                    "/api/oauth/antigravity/status",
                    query: [URLQueryItem(name: "session", value: session)])
                guard let status, status.done else { continue }
                self.agOAuth = nil
                if status.success {
                    await self.refresh()
                } else {
                    self.error = status.error ?? "Antigravity sign-in failed"
                }
                return
            }
        }
    }

    private func blankToNil(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return text.trimmingCharacters(in: .whitespaces)
    }
}

nonisolated struct EmptyBody: Encodable {}

nonisolated enum WorkbuddyKeying {
    static func status(in accounts: [WorkbuddyAccountStatus],
                       for account: AccountView) -> WorkbuddyAccountStatus? {
        if let uid = account.workbuddyUid, !uid.isEmpty,
           let match = accounts.first(where: { $0.uid == uid }) {
            return match
        }
        if let nickname = account.workbuddyNickname, !nickname.isEmpty,
           let match = accounts.first(where: { $0.nickname == nickname }) {
            return match
        }
        return accounts.first(where: { $0.uid == account.name })
    }
}
