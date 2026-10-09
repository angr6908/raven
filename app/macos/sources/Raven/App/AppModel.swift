import AppKit
import Foundation
import Observation
import SwiftUI

enum Page: Hashable {
    case models, pinned
    case provider(UUID)
    case source(RouteSource)
    case overview, usage, accounts, pricing
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
    case provider, family

    var id: String { rawValue }

    var shortTitle: String {
        switch self {
        case .provider: "Provider"
        case .family: "Family"
        }
    }
}

enum ModelSort: String, CaseIterable, Identifiable {
    case name, context

    var id: String { rawValue }
}

struct ModelGroup: Identifiable {
    var id: String
    var title: String
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
    var sourceRemoval: UUID?
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

    var focusedSource: RouteSource? {
        guard case .source(let source) = page else { return nil }
        return source
    }

    var focusedUpstream: UUID? {
        guard case .source(.provider(let id)) = page else { return nil }
        return id
    }

    var canEditProvider: Bool {
        focusedUpstream != nil || !(activeProvider?.isBuiltIn ?? true)
    }

    func title(for page: Page) -> String {
        switch page {
        case .models: "Models"
        case .pinned: "Pinned"
        case .provider(let id): store.provider(id: id)?.name ?? "Provider"
        case .overview: "Overview"
        case .usage: "Usage"
        case .source(let source): ProvidersPanelStore.shared.title(of: source)
        case .accounts: "Accounts"
        case .pricing: "Pricing"
        }
    }

    func matches(_ item: ModelItem) -> Bool {
        guard isSearching else { return true }
        return item.entry.modelID.lowercased().contains(query)
            || item.entry.owner.lowercased().contains(query)
            || providerTitle(item).lowercased().contains(query)
            || item.entry.family.title.lowercased().contains(query)
    }

    func providerTitle(_ item: ModelItem) -> String {
        let panel = ProvidersPanelStore.shared
        guard item.provider.isBuiltIn, let source = panel.source(serving: item.entry.modelID) else {
            return item.provider.name
        }
        return panel.title(of: source)
    }

    func items(on page: Page) -> [ModelItem] {
        switch page {
        case .pinned: store.pinnedItems
        case .provider(let id): store.provider(id: id).map { store.items(of: $0) } ?? []
        case .source(let source): routedItems(source)
        default: store.libraryItems
        }
    }

    func routedItems(_ source: RouteSource) -> [ModelItem] {
        let panel = ProvidersPanelStore.shared
        guard let entry = panel.entry(source) else { return [] }
        let raven = LocalProxy.provider
        let served = Dictionary(store.entries(of: raven).map { ($0.modelID, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<String> = []
        return entry.models.compactMap { def in
            let id = RoutingTable.clientID(def)
            guard !def.name.trimmingCharacters(in: .whitespaces).isEmpty, seen.insert(id).inserted else { return nil }
            let model = served[id] ?? ModelEntry(modelID: id, ownedBy: panel.title(of: source),
                                                 contextWindow: def.maxContextLength)
            return ModelItem(provider: raven, entry: model)
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
        case .family:
            let buckets = Dictionary(grouping: visible) { $0.entry.family }
            return buckets
                .map { family, items in
                    ModelGroup(id: "family/\(family.title)", title: family.title, items: items)
                }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .provider:
            if case .source = page {
                return [ModelGroup(id: "all", title: "", items: visible)]
            }
            if case .provider = page {
                let buckets = Dictionary(grouping: visible) { $0.entry.owner }
                return buckets
                    .map { owner, items in
                        ModelGroup(id: "owner/\(owner)", title: owner, items: items)
                    }
                    .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            }
            let panel = ProvidersPanelStore.shared
            var routed: [RouteSource: [ModelItem]] = [:]
            var direct: [UUID: [ModelItem]] = [:]
            var unrouted: [ModelItem] = []
            for item in visible {
                if !item.provider.isBuiltIn {
                    direct[item.provider.id, default: []].append(item)
                } else if let source = panel.source(serving: item.entry.modelID) {
                    routed[source, default: []].append(item)
                } else {
                    unrouted.append(item)
                }
            }
            let sources = ChannelSpec.all.map { RouteSource.channel($0.kind) } + panel.upstreams.map { RouteSource.provider($0.id) }
            var groups = sources.compactMap { source in
                routed[source].map { ModelGroup(id: "source/\(source)", title: panel.title(of: source), items: $0) }
            }
            groups += store.customProviders.compactMap { provider in
                direct[provider.id].map { ModelGroup(id: "provider/\(provider.id)", title: provider.name, items: $0) }
            }
            if !unrouted.isEmpty {
                groups.append(ModelGroup(id: "unrouted", title: "", items: unrouted))
            }
            return groups
        }
    }

    func addProvider() {
        sheet = .provider(ProviderDraft())
    }

    func edit(_ provider: Provider) {
        sheet = .provider(ProviderDraft(provider))
    }

    func edit(upstream id: UUID) {
        guard let entry = ProvidersPanelStore.shared.entry(.provider(id)) else { return }
        sheet = .provider(ProviderDraft(upstream: id, entry: entry))
    }

    func commit(_ draft: ProviderDraft) {
        let panel = ProvidersPanelStore.shared
        guard draft.viaRaven else {
            guard let provider = store.apply(draft) else { return }
            if let upstream = draft.upstreamID { panel.remove(upstream) }
            sheet = nil
            page = .provider(provider.id)
            return
        }
        guard panel.providers != nil else {
            draft.validationMessage = "Raven isn't running. Turn off Route through Raven to connect directly."
            return
        }
        let taken = panel.upstreams.filter { $0.id != draft.upstreamID }.map { $0.entry.name }
        guard let entry = draft.routedEntry(taken: taken) else { return }
        let id: UUID
        if let upstream = draft.upstreamID {
            panel.edit(.provider(upstream)) { existing in
                existing.name = entry.name
                existing.baseUrl = entry.baseUrl
                existing.kind = entry.kind
                existing.apiKeyEntries = entry.apiKeyEntries
            }
            id = upstream
        } else {
            guard let added = panel.add(entry) else { return }
            if draft.isEditing, let direct = store.provider(id: draft.id) {
                store.removeProvider(direct)
            }
            id = added
        }
        sheet = nil
        page = .source(.provider(id))
        panel.sync(.provider(id))
    }

    func editCurrentProvider() {
        if let id = focusedUpstream {
            edit(upstream: id)
        } else if let provider = activeProvider, !provider.isBuiltIn {
            edit(provider)
        }
    }

    func removeCurrentProvider() {
        if let id = focusedUpstream {
            sourceRemoval = id
        } else if let provider = activeProvider, !provider.isBuiltIn {
            confirmRemoval(of: provider)
        }
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

    func removePendingSource() {
        guard let id = sourceRemoval else { return }
        if focusedUpstream == id { page = .models }
        ProvidersPanelStore.shared.remove(id)
        sourceRemoval = nil
    }

    func refresh(_ provider: Provider) {
        Task { await store.refresh(provider) }
    }

    func refreshAll() {
        ProvidersPanelStore.shared.syncAll()
        Task { await store.refreshAll() }
    }

    func refreshCurrent() {
        switch page {
        case .overview, .usage:
            UsageStore.shared.fetchSnapshot()
        case .accounts:
            Task { await AccountsStore.shared.refresh() }
        case .source(let source):
            ProvidersPanelStore.shared.sync(source)
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
