import AppKit
import Foundation
import Observation
import SwiftUI

enum Page: Hashable {
    case models, pinned, recents
    case provider(UUID)
    case overview, usage, accounts, routing, pricing

    var isLaunch: Bool {
        switch self {
        case .models, .pinned, .recents, .provider: true
        default: false
        }
    }
}

enum AccountKind: String, Identifiable {
    case workbuddy, antigravity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .workbuddy: "WorkBuddy"
        case .antigravity: "Antigravity"
        }
    }
}

enum Sheet: Identifiable {
    case provider(ProviderDraft)
    case script
    case quickLaunch
    case addAccount(AccountKind)

    var id: String {
        switch self {
        case .provider(let draft): "provider/\(draft.id)"
        case .script: "script"
        case .quickLaunch: "quick"
        case .addAccount(let kind): "account/\(kind.rawValue)"
        }
    }
}

enum ModelGrouping: String, CaseIterable, Identifiable {
    case provider, family, none

    var id: String { rawValue }

    var shortTitle: String {
        switch self {
        case .provider: "Provider"
        case .family: "Family"
        case .none: "None"
        }
    }

    var title: String {
        switch self {
        case .provider: "Provider"
        case .family: "Model Family"
        case .none: "No Grouping"
        }
    }
}

enum ModelSort: String, CaseIterable, Identifiable {
    case name, context

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: "Name"
        case .context: "Context Window"
        }
    }
}

struct ModelGroup: Identifiable {
    var id: String
    var title: String
    var symbol: String
    var tint: Color
    var items: [ModelItem]
}

@MainActor
@Observable
final class AppModel {
    let store: ProviderStore

    var page: Page = .models {
        didSet {
            guard page != oldValue else { return }
            search = ""
        }
    }
    var search = ""
    var sheet: Sheet?
    var removal: Provider?
    var launchError: String?
    var isChoosingFolder = false
    var isLaunching = false
    var copiedScript = false

    init(store: ProviderStore) {
        self.store = store
    }

    var query: String {
        search.trimmingCharacters(in: .whitespaces).lowercased()
    }

    var isSearching: Bool { !query.isEmpty }

    var focusedProvider: Provider? {
        guard case .provider(let id) = page else { return nil }
        return store.provider(id: id)
    }

    var activeProvider: Provider? {
        focusedProvider ?? store.selectedItem?.provider
    }

    func title(for page: Page) -> String {
        switch page {
        case .models: "Models"
        case .pinned: "Pinned"
        case .recents: "Recents"
        case .provider(let id): store.provider(id: id)?.name ?? "Provider"
        case .overview: "Overview"
        case .usage: "Usage"
        case .accounts: "Accounts"
        case .routing: "Routing"
        case .pricing: "Pricing"
        }
    }

    func matches(_ item: ModelItem) -> Bool {
        guard isSearching else { return true }
        return item.entry.modelID.lowercased().contains(query)
            || item.entry.owner.lowercased().contains(query)
            || item.provider.name.lowercased().contains(query)
            || item.entry.family.title.lowercased().contains(query)
    }

    func items(on page: Page) -> [ModelItem] {
        switch page {
        case .pinned: store.pinnedItems
        case .provider(let id): store.provider(id: id).map { store.items(of: $0) } ?? []
        default: store.libraryItems
        }
    }

    func groups(on page: Page, grouping: ModelGrouping, sort: ModelSort) -> [ModelGroup] {
        let visible = items(on: page).filter(matches).sorted { lhs, rhs in
            switch sort {
            case .name:
                return lhs.entry.modelID.localizedStandardCompare(rhs.entry.modelID) == .orderedAscending
            case .context:
                let left = store.effectiveWindow(lhs), right = store.effectiveWindow(rhs)
                if left != right { return left > right }
                return lhs.entry.modelID.localizedStandardCompare(rhs.entry.modelID) == .orderedAscending
            }
        }
        guard !visible.isEmpty else { return [] }

        switch grouping {
        case .none:
            return [ModelGroup(id: "all", title: "", symbol: "", tint: .secondary, items: visible)]
        case .family:
            let buckets = Dictionary(grouping: visible) { $0.entry.family }
            return buckets
                .map { family, items in
                    ModelGroup(id: "family/\(family.title)", title: family.title, symbol: family.symbol,
                               tint: family.tint, items: items)
                }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .provider:
            if case .provider = page {
                let buckets = Dictionary(grouping: visible) { $0.entry.owner }
                return buckets
                    .map { owner, items in
                        ModelGroup(id: "owner/\(owner)", title: owner, symbol: "person.2", tint: .secondary, items: items)
                    }
                    .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            }
            return store.providers.compactMap { provider in
                let owned = visible.filter { $0.provider.id == provider.id }
                return owned.isEmpty ? nil
                    : ModelGroup(id: "provider/\(provider.id)", title: provider.name, symbol: "server.rack",
                                 tint: provider.accent, items: owned)
            }
        }
    }

    func recents(matching text: String? = nil) -> [RecentLaunch] {
        let needle = (text ?? query).lowercased()
        guard !needle.isEmpty else { return store.recents }
        return store.recents.filter {
            $0.modelID.lowercased().contains(needle)
                || $0.folderName.lowercased().contains(needle)
                || $0.client.displayName.lowercased().contains(needle)
        }
    }

    func addProvider() {
        sheet = .provider(ProviderDraft())
    }

    func addLocalProxy() {
        sheet = .provider(.localProxy())
    }

    func edit(_ provider: Provider) {
        sheet = .provider(ProviderDraft(provider))
    }

    func commit(_ draft: ProviderDraft) {
        guard let provider = store.apply(draft) else { return }
        sheet = nil
        page = .provider(provider.id)
    }

    func confirmRemoval(of provider: Provider) {
        removal = provider
    }

    func removePending() {
        guard let provider = removal else { return }
        if focusedProvider?.id == provider.id { page = .models }
        store.removeProvider(provider)
        removal = nil
    }

    func refresh(_ provider: Provider) {
        Task { await store.refresh(provider) }
    }

    func refreshAll() {
        Task { await store.refreshAll() }
    }

    func refreshCurrent() {
        switch page {
        case .overview, .usage:
            UsageStore.shared.fetchSnapshot()
        case .accounts:
            Task { await AccountsStore.shared.refresh() }
        case .routing:
            ProvidersPanelStore.shared.reload()
        case .pricing:
            PricingStore.shared.refresh()
        default:
            if let provider = activeProvider {
                refresh(provider)
            } else {
                refreshAll()
            }
        }
    }

    func select(_ item: ModelItem) {
        store.selection = item.ref
    }

    func launch(_ item: ModelItem? = nil) {
        if let item { store.selection = item.ref }
        guard store.canLaunch, !isLaunching else { return }
        isLaunching = true
        Task {
            defer { isLaunching = false }
            do {
                try await store.launch()
            } catch {
                launchError = error.localizedDescription
            }
        }
    }

    func launch(_ ref: ModelRef) {
        guard let item = store.item(ref) else { return }
        launch(item)
    }

    func relaunch(_ recent: RecentLaunch) {
        store.restore(recent)
        launch()
    }

    func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func copyScript() {
        guard let script = store.launchScript() else { return }
        copy(script)
        copiedScript = true
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            copiedScript = false
        }
    }

    func revealConfig() {
        NSWorkspace.shared.activateFileViewerSelecting([ProviderStore.configFile])
    }

    func revealWorkdir() {
        NSWorkspace.shared.activateFileViewerSelecting([store.workdir])
    }

    func setWorkdir(_ url: URL) {
        store.workdir = url
        store.rememberWorkdir()
    }
}
